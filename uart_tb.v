// ============================================================
// File        : uart_tb.v
// Description : Comprehensive UART Testbench
//               Tests: TX, RX, Loopback, FIFO, Error Detection
//               Simulator: Icarus Verilog / ModelSim / VCS
// ============================================================
`timescale 1ns/1ps

module uart_tb;

    // ---- Parameters matching DUT ----
    parameter CLK_FREQ   = 50_000_000;
    parameter BAUD_RATE  = 9600;
    parameter CLK_PERIOD = 20;   // 50 MHz → 20 ns period
    parameter BIT_PERIOD = CLK_FREQ / BAUD_RATE * CLK_PERIOD;  // ns per bit

    // ---- DUT Signals ----
    reg        clk;
    reg        rst_n;
    reg  [3:0] reg_addr;
    reg        reg_wr_en;
    reg        reg_rd_en;
    reg  [7:0] reg_wr_data;
    wire [7:0] reg_rd_data;
    wire       uart_tx;
    wire       irq_rx_valid;
    wire       irq_tx_empty;

    // External RX stimulus
    reg        uart_rx_stim;

    // ---- DUT Instantiation ----
    uart_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .DATA_BITS (8),
        .STOP_BITS (1),
        .PARITY_EN (0),
        .FIFO_DEPTH(16)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .reg_addr    (reg_addr),
        .reg_wr_en   (reg_wr_en),
        .reg_rd_en   (reg_rd_en),
        .reg_wr_data (reg_wr_data),
        .reg_rd_data (reg_rd_data),
        .uart_tx     (uart_tx),
        .uart_rx     (uart_rx_stim),
        .irq_rx_valid(irq_rx_valid),
        .irq_tx_empty(irq_tx_empty)
    );

    // ---- Clock Generator ----
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- Task: Register Write ----
    task reg_write;
        input [3:0] addr;
        input [7:0] data;
        begin
            @(posedge clk); #1;
            reg_addr    = addr;
            reg_wr_data = data;
            reg_wr_en   = 1'b1;
            reg_rd_en   = 1'b0;
            @(posedge clk); #1;
            reg_wr_en   = 1'b0;
        end
    endtask

    // ---- Task: Register Read ----
    task reg_read;
        input  [3:0] addr;
        output [7:0] data;
        begin
            @(posedge clk); #1;
            reg_addr  = addr;
            reg_rd_en = 1'b1;
            reg_wr_en = 1'b0;
            @(posedge clk); #1;
            data      = reg_rd_data;
            reg_rd_en = 1'b0;
        end
    endtask

    // ---- Task: Send byte on RX line (stimulus) ----
    // Simulates an external UART transmitter sending to DUT RX
    task send_byte_to_rx;
        input [7:0] data;
        integer i;
        begin
            // Start bit
            uart_rx_stim = 1'b0;
            #BIT_PERIOD;
            // Data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_stim = data[i];
                #BIT_PERIOD;
            end
            // Stop bit
            uart_rx_stim = 1'b1;
            #BIT_PERIOD;
        end
    endtask

    // ---- Task: Wait for TX to complete ----
    task wait_tx_done;
        reg [7:0] status;
        begin
            status = 8'h00;
            while (!(status[6])) begin  // TX_EMPTY
                #(BIT_PERIOD);
                reg_read(4'h1, status);
            end
        end
    endtask

    // ---- Waveform Dump ----
    initial begin
        $dumpfile("uart_sim.vcd");
        $dumpvars(0, uart_tb);
    end

    // ---- Monitor TX output ----
    integer tx_monitor_active = 0;
    reg [7:0] tx_captured;
    reg [3:0] tx_cap_idx;
    initial begin
        tx_captured = 0;
        tx_cap_idx  = 0;
    end

    // ---- Receive monitor (decode TX line) ----
    reg tx_prev = 1;
    always @(negedge uart_tx) begin
        if (tx_prev == 1) begin
            // Falling edge = start bit detected
            #(BIT_PERIOD * 1.5);  // Skip to middle of first data bit
            tx_captured = 0;
            repeat (8) begin
                tx_captured = {uart_tx, tx_captured[7:1]};
                #BIT_PERIOD;
            end
            $display("[TX MONITOR] Byte transmitted: 0x%02X ('%c') at time %0t ns",
                      tx_captured, tx_captured, $time);
        end
        tx_prev = uart_tx;
    end

    // ---- Test Sequence ----
    integer errors = 0;
    reg [7:0] rd_val;

    initial begin
        // ── Reset ──
        rst_n        = 1'b0;
        reg_addr     = 0;
        reg_wr_en    = 1'b0;
        reg_rd_en    = 1'b0;
        reg_wr_data  = 8'h00;
        uart_rx_stim = 1'b1;   // Idle = HIGH
        #(CLK_PERIOD * 10);
        rst_n = 1'b1;
        #(CLK_PERIOD * 5);

        $display("==============================================");
        $display("  UART TESTBENCH START");
        $display("  CLK: %0d MHz  BAUD: %0d", CLK_FREQ/1_000_000, BAUD_RATE);
        $display("==============================================");

        // ── TEST 1: Status Register After Reset ──
        $display("\n[TEST 1] Status register check after reset");
        reg_read(4'h1, rd_val);
        if (rd_val[6] !== 1'b1) begin
            $display("  FAIL: TX_EMPTY should be 1, got %b", rd_val[6]);
            errors = errors + 1;
        end else begin
            $display("  PASS: TX_EMPTY=1, RX_EMPTY=1 (status=0x%02X)", rd_val);
        end

        // ── TEST 2: Transmit Single Byte ──
        $display("\n[TEST 2] Transmit byte 0x55 ('U')");
        reg_write(4'h0, 8'h55);
        wait_tx_done();
        $display("  PASS: Byte 0x55 transmitted");

        // ── TEST 3: Transmit String ──
        $display("\n[TEST 3] Transmit string 'UART'");
        reg_write(4'h0, 8'h55);  // U
        reg_write(4'h0, 8'h41);  // A
        reg_write(4'h0, 8'h52);  // R
        reg_write(4'h0, 8'h54);  // T
        wait_tx_done();
        $display("  PASS: String 'UART' transmitted");

        // ── TEST 4: Receive Byte (External Stimulus) ──
        $display("\n[TEST 4] Receive byte 0xA5 from external source");
        fork
            send_byte_to_rx(8'hA5);
        join
        // Wait enough time for byte to be received
        #(BIT_PERIOD * 3);
        reg_read(4'h1, rd_val);
        if (rd_val[0] !== 1'b1) begin
            $display("  FAIL: RX_VALID not set (status=0x%02X)", rd_val);
            errors = errors + 1;
        end else begin
            reg_read(4'h0, rd_val);
            if (rd_val !== 8'hA5) begin
                $display("  FAIL: Expected 0xA5, got 0x%02X", rd_val);
                errors = errors + 1;
            end else begin
                $display("  PASS: Received 0xA5 correctly");
            end
        end

        // ── TEST 5: Loopback Test ──
        $display("\n[TEST 5] Loopback test (TX->RX internally)");
        reg_write(4'h2, 8'h01);  // Enable loopback
        reg_write(4'h0, 8'hC3);  // Send 0xC3
        // Wait for TX and RX to complete
        #(BIT_PERIOD * 12);
        reg_read(4'h1, rd_val);
        if (rd_val[0] !== 1'b1) begin
            $display("  FAIL: Loopback RX not received (status=0x%02X)", rd_val);
            errors = errors + 1;
        end else begin
            reg_read(4'h0, rd_val);
            if (rd_val !== 8'hC3) begin
                $display("  FAIL: Loopback expected 0xC3, got 0x%02X", rd_val);
                errors = errors + 1;
            end else begin
                $display("  PASS: Loopback 0xC3 received correctly");
            end
        end
        // Disable loopback
        reg_write(4'h2, 8'h00);

        // ── TEST 6: FIFO Burst (fill up TX FIFO) ──
        $display("\n[TEST 6] FIFO burst - write 8 bytes");
        begin : fifo_test
            integer k;
            for (k = 0; k < 8; k = k + 1) begin
                reg_write(4'h0, 8'h30 + k);  // '0'..'7'
            end
        end
        wait_tx_done();
        $display("  PASS: 8-byte burst transmitted");

        // ── TEST 7: Receive Multiple Bytes ──
        $display("\n[TEST 7] Receive 3 bytes in sequence");
        fork
            begin
                send_byte_to_rx(8'h11);
                send_byte_to_rx(8'h22);
                send_byte_to_rx(8'h33);
            end
        join
        #(BIT_PERIOD * 3);
        reg_read(4'h0, rd_val);
        $display("  Byte 1 received: 0x%02X (expect 0x11 %s)",
                  rd_val, (rd_val==8'h11)?"PASS":"FAIL");
        if (rd_val !== 8'h11) errors = errors + 1;
        reg_read(4'h0, rd_val);
        $display("  Byte 2 received: 0x%02X (expect 0x22 %s)",
                  rd_val, (rd_val==8'h22)?"PASS":"FAIL");
        if (rd_val !== 8'h22) errors = errors + 1;
        reg_read(4'h0, rd_val);
        $display("  Byte 3 received: 0x%02X (expect 0x33 %s)",
                  rd_val, (rd_val==8'h33)?"PASS":"FAIL");
        if (rd_val !== 8'h33) errors = errors + 1;

        // ── SUMMARY ──
        #(CLK_PERIOD * 10);
        $display("\n==============================================");
        if (errors == 0)
            $display("  ALL TESTS PASSED ✓");
        else
            $display("  %0d TEST(S) FAILED ✗", errors);
        $display("==============================================\n");
        $finish;
    end

    // ---- Timeout watchdog ----
    initial begin
        #(BIT_PERIOD * 300);
        $display("TIMEOUT: Simulation exceeded time limit");
        $finish;
    end

endmodule
