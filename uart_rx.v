// ============================================================
// File        : uart_rx.v
// Description : UART Receiver with 16x Oversampling
//               - Detects start bit falling edge
//               - Samples each bit at mid-point (sample 8 of 16)
//               - Majority vote on 3 centre samples (7,8,9) for noise rejection
//               - Optional parity checking
//               - Flags: frame error, parity error
// Frame: [START][D0][D1][D2][D3][D4][D5][D6][D7][PARITY?][STOP]
// ============================================================

module uart_rx #(
    parameter DATA_BITS  = 8,
    parameter STOP_BITS  = 1,
    parameter PARITY_EN  = 0,
    parameter PARITY_ODD = 0
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             baud_tick_x16, // 16x oversampling tick
    // Serial input
    input  wire             rx_in,         // UART RX line (should be synchronised)
    // Data output
    output reg  [DATA_BITS-1:0] rx_data,  // Received byte
    output reg              rx_valid,      // High for 1 cycle when data ready
    // Error flags
    output reg              rx_parity_err, // Parity mismatch
    output reg              rx_frame_err   // Stop bit not HIGH
);

    // ---- Synchroniser (2-FF metastability protection) ----
    reg rx_sync1, rx_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_sync1 <= 1'b1; rx_sync2 <= 1'b1; end
        else        begin rx_sync1 <= rx_in; rx_sync2 <= rx_sync1; end
    end
    wire rx_s = rx_sync2;

    // ---- State Machine ----
    localparam S_IDLE   = 3'd0;
    localparam S_START  = 3'd1;
    localparam S_DATA   = 3'd2;
    localparam S_PARITY = 3'd3;
    localparam S_STOP   = 3'd4;

    reg [2:0] state;
    reg [3:0] tick_cnt;   // 0..15 oversampling counter
    reg [2:0] bit_idx;    // 0..DATA_BITS-1
    reg [DATA_BITS-1:0] shift_reg;
    reg [1:0] stop_cnt;

    // 3-sample majority vote at ticks 7,8,9 of each bit period
    reg s7, s8, s9;
    wire majority = (s7 & s8) | (s8 & s9) | (s7 & s9);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            tick_cnt      <= 0;
            bit_idx       <= 0;
            shift_reg     <= 0;
            rx_data       <= 0;
            rx_valid      <= 1'b0;
            rx_parity_err <= 1'b0;
            rx_frame_err  <= 1'b0;
            s7 <= 0; s8 <= 0; s9 <= 0;
            stop_cnt      <= 0;
        end else begin
            rx_valid      <= 1'b0;  // Default de-assert
            rx_parity_err <= 1'b0;
            rx_frame_err  <= 1'b0;

            case (state)

                // ---- IDLE: watch for falling edge (start bit) ----
                S_IDLE: begin
                    if (!rx_s) begin           // START bit detected
                        tick_cnt <= 1;
                        state    <= S_START;
                    end
                end

                // ---- START: sample at mid-point (tick 8) to confirm ----
                S_START: begin
                    if (baud_tick_x16) begin
                        tick_cnt <= tick_cnt + 1;
                        if (tick_cnt == 7)  s7 <= rx_s;
                        if (tick_cnt == 8)  s8 <= rx_s;
                        if (tick_cnt == 9)  s9 <= rx_s;
                        if (tick_cnt == 15) begin
                            tick_cnt <= 0;
                            bit_idx  <= 0;
                            if (!majority)  // Valid low start bit
                                state <= S_DATA;
                            else
                                state <= S_IDLE; // False start, back to idle
                        end
                    end
                end

                // ---- DATA BITS: 16 ticks per bit, sample at 7,8,9 ----
                S_DATA: begin
                    if (baud_tick_x16) begin
                        tick_cnt <= tick_cnt + 1;
                        if (tick_cnt == 7)  s7 <= rx_s;
                        if (tick_cnt == 8)  s8 <= rx_s;
                        if (tick_cnt == 9)  s9 <= rx_s;
                        if (tick_cnt == 15) begin
                            tick_cnt <= 0;
                            // LSB first: shift in from MSB side, then reverse
                            shift_reg <= {majority, shift_reg[DATA_BITS-1:1]};
                            if (bit_idx == DATA_BITS - 1) begin
                                bit_idx <= 0;
                                state   <= (PARITY_EN) ? S_PARITY : S_STOP;
                            end else begin
                                bit_idx <= bit_idx + 1;
                            end
                        end
                    end
                end

                // ---- PARITY BIT ----
                S_PARITY: begin
                    if (baud_tick_x16) begin
                        tick_cnt <= tick_cnt + 1;
                        if (tick_cnt == 7)  s7 <= rx_s;
                        if (tick_cnt == 8)  s8 <= rx_s;
                        if (tick_cnt == 9)  s9 <= rx_s;
                        if (tick_cnt == 15) begin
                            tick_cnt <= 0;
                            // Check parity: XOR of data + received parity bit must equal 0 (even) or 1 (odd)
                            if (majority != ((^shift_reg) ^ (PARITY_ODD ? 1'b1 : 1'b0)))
                                rx_parity_err <= 1'b1;
                            state <= S_STOP;
                        end
                    end
                end

                // ---- STOP BIT(S) ----
                S_STOP: begin
                    if (baud_tick_x16) begin
                        tick_cnt <= tick_cnt + 1;
                        if (tick_cnt == 7)  s7 <= rx_s;
                        if (tick_cnt == 8)  s8 <= rx_s;
                        if (tick_cnt == 9)  s9 <= rx_s;
                        if (tick_cnt == 15) begin
                            tick_cnt <= 0;
                            if (!majority) begin
                                rx_frame_err <= 1'b1; // Stop bit should be HIGH
                            end
                            if (stop_cnt == STOP_BITS - 1) begin
                                stop_cnt <= 0;
                                rx_data  <= shift_reg;
                                rx_valid <= 1'b1;
                                state    <= S_IDLE;
                            end else begin
                                stop_cnt <= stop_cnt + 1;
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
