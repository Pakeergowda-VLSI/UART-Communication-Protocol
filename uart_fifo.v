// ============================================================
// File        : uart_fifo.v
// Description : Synchronous FIFO buffer for UART TX / RX
//               - Parameterised depth and data width
//               - Full / Empty / Half-full flags
//               - Used to decouple CPU interface from UART core
// ============================================================

module uart_fifo #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 16     // Must be power of 2
)(
    input  wire                  clk,
    input  wire                  rst_n,
    // Write port
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    // Read port
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    // Status
    output wire                  half_full,
    output wire [$clog2(FIFO_DEPTH):0] count  // Number of entries
);

    localparam ADDR_W = $clog2(FIFO_DEPTH);

    // ---- Storage ----
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    // ---- Pointers ----
    reg [ADDR_W:0] wr_ptr;  // Extra bit for full/empty detection
    reg [ADDR_W:0] rd_ptr;

    // ---- Status Flags ----
    assign count     = wr_ptr - rd_ptr;
    assign full      = (count == FIFO_DEPTH);
    assign empty     = (count == 0);
    assign half_full = (count >= FIFO_DEPTH / 2);

    // ---- Read Data ----
    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];

    // ---- Write Logic ----
    always @(posedge clk) begin
        if (wr_en && !full)
            mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
    end

    // ---- Pointer Updates ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1;
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1;
        end
    end

endmodule
