// ============================================================
// File        : uart_baud_gen.v
// Description : Baud Rate Generator for UART
//               Generates tick pulses at the configured baud rate
//               Default: 9600 baud @ 50 MHz system clock
//               Tick pulse = every (CLK_FREQ / BAUD_RATE) cycles
// ============================================================

module uart_baud_gen #(
    parameter CLK_FREQ  = 50_000_000,  // 50 MHz system clock
    parameter BAUD_RATE = 9600          // Default baud rate
)(
    input  wire clk,
    input  wire rst_n,          // Active-low reset
    output reg  baud_tick,      // 1-cycle pulse at baud rate
    output reg  baud_tick_x16   // 16x oversampling tick for RX
);

    // ---- Parameters ----
    localparam integer BAUD_DIV     = CLK_FREQ / BAUD_RATE;        // ~5208 for 9600 @ 50MHz
    localparam integer BAUD_DIV_X16 = CLK_FREQ / (BAUD_RATE * 16); // ~325 for 16x oversample

    localparam BAUD_CTR_BITS  = $clog2(BAUD_DIV);
    localparam BAUD16_CTR_BITS = $clog2(BAUD_DIV_X16);

    // ---- Counters ----
    reg [BAUD_CTR_BITS-1:0]   baud_ctr;
    reg [BAUD16_CTR_BITS-1:0] baud16_ctr;

    // ---- Baud Tick (1x) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_ctr  <= 0;
            baud_tick <= 1'b0;
        end else begin
            if (baud_ctr == BAUD_DIV - 1) begin
                baud_ctr  <= 0;
                baud_tick <= 1'b1;
            end else begin
                baud_ctr  <= baud_ctr + 1;
                baud_tick <= 1'b0;
            end
        end
    end

    // ---- Baud Tick x16 (oversampling for RX) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud16_ctr    <= 0;
            baud_tick_x16 <= 1'b0;
        end else begin
            if (baud16_ctr == BAUD_DIV_X16 - 1) begin
                baud16_ctr    <= 0;
                baud_tick_x16 <= 1'b1;
            end else begin
                baud16_ctr    <= baud16_ctr + 1;
                baud_tick_x16 <= 1'b0;
            end
        end
    end

endmodule
