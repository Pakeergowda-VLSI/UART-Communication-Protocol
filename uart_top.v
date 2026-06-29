// ============================================================
// File        : uart_top.v
// Description : UART Top-Level Module
//               Integrates: Baud Generator + TX + RX + FIFOs
//               Register-mapped interface (APB-like, simplified)
//
// Register Map (8-bit address space):
//   0x00 - DATA_REG  : Write = TX data, Read = RX data
//   0x04 - STATUS_REG: [7]TX_FULL [6]TX_EMPTY [5]RX_FULL [4]RX_EMPTY
//                      [3]TX_BUSY [2]PARITY_ERR [1]FRAME_ERR [0]RX_VALID
//   0x08 - CTRL_REG  : [1]PARITY_EN [0]LOOPBACK_EN
// ============================================================

module uart_top #(
    parameter CLK_FREQ   = 50_000_000,
    parameter BAUD_RATE  = 9600,
    parameter DATA_BITS  = 8,
    parameter STOP_BITS  = 1,
    parameter PARITY_EN  = 0,
    parameter PARITY_ODD = 0,
    parameter FIFO_DEPTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // Register bus interface
    input  wire [3:0]  reg_addr,
    input  wire        reg_wr_en,
    input  wire        reg_rd_en,
    input  wire [7:0]  reg_wr_data,
    output reg  [7:0]  reg_rd_data,

    // UART I/O pins
    output wire        uart_tx,
    input  wire        uart_rx,

    // Interrupt output
    output wire        irq_rx_valid,  // Fires when RX byte received
    output wire        irq_tx_empty   // Fires when TX FIFO empties
);

    // ---- Internal signals ----
    wire baud_tick;
    wire baud_tick_x16;

    // TX path
    wire        tx_ready;
    wire        tx_busy;
    wire        tx_fifo_empty;
    wire        tx_fifo_full;
    wire [DATA_BITS-1:0] tx_fifo_rd_data;
    wire        tx_valid_int;
    reg         tx_fifo_rd_en;

    // RX path
    wire [DATA_BITS-1:0] rx_data;
    wire        rx_valid;
    wire        rx_parity_err;
    wire        rx_frame_err;
    wire        rx_fifo_empty;
    wire        rx_fifo_full;
    wire [DATA_BITS-1:0] rx_fifo_rd_data;

    // Control register
    reg  loopback_en;
    reg  parity_en_dyn;

    // Loopback mux: TX data loops back to RX input when enabled
    wire rx_line = loopback_en ? uart_tx : uart_rx;

    // ---- Status / Error latches ----
    reg parity_err_latch, frame_err_latch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parity_err_latch <= 0;
            frame_err_latch  <= 0;
        end else begin
            if (rx_parity_err) parity_err_latch <= 1'b1;
            if (rx_frame_err)  frame_err_latch  <= 1'b1;
            // Clear on status read
            if (reg_rd_en && reg_addr == 4'h1) begin
                parity_err_latch <= 1'b0;
                frame_err_latch  <= 1'b0;
            end
        end
    end

    // ---- Baud Rate Generator ----
    uart_baud_gen #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_baud_gen (
        .clk          (clk),
        .rst_n        (rst_n),
        .baud_tick    (baud_tick),
        .baud_tick_x16(baud_tick_x16)
    );

    // ---- TX FIFO ----
    uart_fifo #(
        .DATA_WIDTH(DATA_BITS),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_tx_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (reg_wr_en && reg_addr == 4'h0),
        .wr_data  (reg_wr_data[DATA_BITS-1:0]),
        .full     (tx_fifo_full),
        .rd_en    (tx_fifo_rd_en),
        .rd_data  (tx_fifo_rd_data),
        .empty    (tx_fifo_empty),
        .half_full(),
        .count    ()
    );

    // TX FIFO -> TX core: send next byte when TX is ready and FIFO non-empty
    assign tx_valid_int = !tx_fifo_empty && tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_fifo_rd_en <= 1'b0;
        else
            tx_fifo_rd_en <= tx_valid_int;  // 1-cycle read pulse
    end

    // ---- UART Transmitter ----
    uart_tx #(
        .DATA_BITS (DATA_BITS),
        .STOP_BITS (STOP_BITS),
        .PARITY_EN (PARITY_EN),
        .PARITY_ODD(PARITY_ODD)
    ) u_uart_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_tick (baud_tick),
        .tx_data   (tx_fifo_rd_data),
        .tx_valid  (tx_valid_int),
        .tx_ready  (tx_ready),
        .tx_out    (uart_tx),
        .tx_busy   (tx_busy)
    );

    // ---- UART Receiver ----
    uart_rx #(
        .DATA_BITS (DATA_BITS),
        .STOP_BITS (STOP_BITS),
        .PARITY_EN (PARITY_EN),
        .PARITY_ODD(PARITY_ODD)
    ) u_uart_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .baud_tick_x16(baud_tick_x16),
        .rx_in        (rx_line),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_parity_err(rx_parity_err),
        .rx_frame_err (rx_frame_err)
    );

    // ---- RX FIFO ----
    uart_fifo #(
        .DATA_WIDTH(DATA_BITS),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_rx_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (rx_valid && !rx_fifo_full),
        .wr_data  (rx_data),
        .full     (rx_fifo_full),
        .rd_en    (reg_rd_en && reg_addr == 4'h0),
        .rd_data  (rx_fifo_rd_data),
        .empty    (rx_fifo_empty),
        .half_full(),
        .count    ()
    );

    // ---- Interrupt Lines ----
    assign irq_rx_valid = rx_valid;          // Pulse when byte arrives
    assign irq_tx_empty = tx_fifo_empty;     // Level when TX FIFO drained

    // ---- Register Read ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_rd_data  <= 8'h00;
            loopback_en  <= 1'b0;
            parity_en_dyn<= 1'b0;
        end else begin
            if (reg_rd_en) begin
                case (reg_addr)
                    4'h0: reg_rd_data <= rx_fifo_rd_data;                     // DATA
                    4'h1: reg_rd_data <= {tx_fifo_full, tx_fifo_empty,         // STATUS
                                           rx_fifo_full, rx_fifo_empty,
                                           tx_busy, parity_err_latch,
                                           frame_err_latch, !rx_fifo_empty};
                    4'h2: reg_rd_data <= {6'b0, parity_en_dyn, loopback_en};  // CTRL
                    default: reg_rd_data <= 8'hFF;
                endcase
            end
            // Register Write
            if (reg_wr_en) begin
                case (reg_addr)
                    4'h2: begin
                        loopback_en   <= reg_wr_data[0];
                        parity_en_dyn <= reg_wr_data[1];
                    end
                    default: ; // DATA writes go directly into TX FIFO
                endcase
            end
        end
    end

endmodule
