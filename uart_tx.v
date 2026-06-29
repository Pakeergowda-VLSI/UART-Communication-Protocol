// ============================================================
// File        : uart_tx.v
// Description : UART Transmitter
//               - 8 data bits, 1 start bit, configurable stop bits
//               - Optional parity (NONE / ODD / EVEN)
//               - Ready/valid handshake interface
//               - LSB transmitted first (standard UART)
// Frame: [START][D0][D1][D2][D3][D4][D5][D6][D7][PARITY?][STOP]
// ============================================================

module uart_tx #(
    parameter DATA_BITS  = 8,   // Data word width (7 or 8)
    parameter STOP_BITS  = 1,   // 1 or 2 stop bits
    parameter PARITY_EN  = 0,   // 0=None, 1=Enabled
    parameter PARITY_ODD = 0    // 0=Even parity, 1=Odd parity
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             baud_tick,      // 1 pulse per baud period
    // Data interface
    input  wire [DATA_BITS-1:0] tx_data,   // Byte to transmit
    input  wire             tx_valid,       // Data valid strobe
    output reg              tx_ready,       // Ready to accept data
    // Serial output
    output reg              tx_out,         // UART TX line
    // Status
    output reg              tx_busy         // Transmit in progress
);

    // ---- State Machine ----
    localparam S_IDLE   = 3'd0;
    localparam S_START  = 3'd1;
    localparam S_DATA   = 3'd2;
    localparam S_PARITY = 3'd3;
    localparam S_STOP   = 3'd4;

    reg [2:0] state;
    reg [2:0] bit_idx;      // Current data bit index (0..DATA_BITS-1)
    reg [1:0] stop_cnt;     // Stop bit counter
    reg [DATA_BITS-1:0] shift_reg;  // TX shift register
    reg parity_bit;

    // ---- Parity Calculation ----
    // Computed as XOR of all data bits; inverted for odd parity
    wire parity_calc = (^shift_reg) ^ (PARITY_ODD ? 1'b1 : 1'b0);

    // ---- Transmitter FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tx_out     <= 1'b1;   // Idle line is HIGH
            tx_ready   <= 1'b1;
            tx_busy    <= 1'b0;
            shift_reg  <= 0;
            bit_idx    <= 0;
            stop_cnt   <= 0;
            parity_bit <= 1'b0;
        end else begin
            case (state)

                // ---- IDLE: wait for valid data ----
                S_IDLE: begin
                    tx_out   <= 1'b1;
                    tx_busy  <= 1'b0;
                    if (tx_valid && tx_ready) begin
                        shift_reg  <= tx_data;
                        parity_bit <= (^tx_data) ^ (PARITY_ODD ? 1'b1 : 1'b0);
                        tx_ready   <= 1'b0;
                        tx_busy    <= 1'b1;
                        state      <= S_START;
                    end
                end

                // ---- START BIT (always LOW) ----
                S_START: begin
                    if (baud_tick) begin
                        tx_out  <= 1'b0;
                        bit_idx <= 0;
                        state   <= S_DATA;
                    end
                end

                // ---- DATA BITS (LSB first) ----
                S_DATA: begin
                    if (baud_tick) begin
                        tx_out <= shift_reg[0];
                        shift_reg <= shift_reg >> 1;
                        if (bit_idx == DATA_BITS - 1) begin
                            bit_idx <= 0;
                            state   <= (PARITY_EN) ? S_PARITY : S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end
                end

                // ---- PARITY BIT (optional) ----
                S_PARITY: begin
                    if (baud_tick) begin
                        tx_out <= parity_bit;
                        state  <= S_STOP;
                    end
                end

                // ---- STOP BIT(S) (always HIGH) ----
                S_STOP: begin
                    if (baud_tick) begin
                        tx_out <= 1'b1;
                        if (stop_cnt == STOP_BITS - 1) begin
                            stop_cnt <= 0;
                            tx_ready <= 1'b1;
                            state    <= S_IDLE;
                        end else begin
                            stop_cnt <= stop_cnt + 1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
