// Formal harness for dcache.
//
// The backing store is abstracted with the "watched address" technique: only
// the line that contains f_addr is modelled exactly; reads of every other line
// return unconstrained data. Because f_addr is an arbitrary constant, a proof
// for this one word is a proof for every word.
module dcache_formal #(
    parameter integer AW = 6, DW = 16, WORDS = 2, SETS = 2
) (
    input wire                 clk,
    input wire                 rst_n,
    input wire                 req_valid,
    input wire                 req_we,
    input wire [AW-1:0]        req_addr,
    input wire [DW-1:0]        req_wdata,
    input wire [DW/8-1:0]      req_wstrb,
    input wire                 mem_ack_any,     // memory may take arbitrarily long
    input wire [WORDS*DW-1:0]  mem_rdata_any
);
    localparam integer BO  = $clog2(DW/8);
    localparam integer WO  = $clog2(WORDS);
    localparam integer LAW = AW - BO - WO;

    (* anyconst *) wire [AW-BO-1:0] f_addr;
    wire [LAW-1:0] f_line = f_addr[AW-BO-1:WO];

    wire                req_ready, resp_valid, mem_req, mem_we;
    wire [DW-1:0]       resp_rdata;
    wire [LAW-1:0]      mem_addr;
    wire [WORDS*DW-1:0] mem_wdata;

    // exact model of the watched line only
    reg  [WORDS*DW-1:0] f_mem_line;
    wire mem_ack = mem_req && mem_ack_any && rst_n;   // memory ignores requests during reset
    wire [WORDS*DW-1:0] mem_rdata = (mem_addr == f_line) ? f_mem_line : mem_rdata_any;
    always @(posedge clk)
        if (mem_ack && mem_we && mem_addr == f_line) f_mem_line <= mem_wdata;

    dcache #(.AW(AW), .DW(DW), .WORDS(WORDS), .SETS(SETS)) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .resp_valid(resp_valid), .resp_rdata(resp_rdata),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ack(mem_ack), .mem_rdata(mem_rdata),
        .stat_hit(), .stat_miss(), .stat_writeback(),
        .f_addr(f_addr), .f_mem_word(f_mem_line[f_addr[WO-1:0]*DW +: DW])
    );
endmodule
