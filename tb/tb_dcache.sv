`timescale 1ns/1ps
// Constrained-random simulation of the cache against a flat reference memory.
// The backing store answers after a random delay; traffic mixes hot-set
// locality with conflict-heavy addresses so hits, misses, evictions and
// write-backs are all exercised. Ends with a full read-back of every word.
module tb_dcache;
    localparam integer AW = 14, DW = 32, WORDS = 4, SETS = 16;
    localparam integer LAW = AW - 2 - 2, LW = WORDS * DW, NWORDS = 1 << (AW - 2);

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg              req_valid = 0, req_we = 0;
    reg  [AW-1:0]    req_addr = 0;
    reg  [DW-1:0]    req_wdata = 0;
    reg  [3:0]       req_wstrb = 0;
    wire             req_ready, resp_valid, mem_req, mem_we;
    wire [DW-1:0]    resp_rdata;
    wire [LAW-1:0]   mem_addr;
    wire [LW-1:0]    mem_wdata;
    reg              mem_ack = 0;
    reg  [LW-1:0]    mem_rdata = 0;
    wire             stat_hit, stat_miss, stat_writeback;

    dcache #(.AW(AW), .DW(DW), .WORDS(WORDS), .SETS(SETS)) dut (.*);

    // ---------------------------------------------------------- backing store
    reg [LW-1:0] mem [0:(1<<LAW)-1];
    integer dly = 0;
    always @(posedge clk) begin
        mem_ack <= 0;
        if (mem_req && !mem_ack) begin
            if (dly == 0) begin
                mem_ack <= 1;
                if (mem_we) mem[mem_addr] <= mem_wdata;
                else        mem_rdata <= mem[mem_addr];
                dly = $urandom_range(0, 3);
            end else dly = dly - 1;
        end
    end

    // ---------------------------------------------------------- scoreboard
    reg [DW-1:0] refm [0:NWORDS-1];
    integer hits = 0, misses = 0, wbs = 0, errors = 0, reads = 0, writes = 0, i, b;
    always @(posedge clk) if (rst_n && stat_hit !== 1'bx) begin
        hits   = hits + stat_hit;
        misses = misses + stat_miss;
        wbs    = wbs + stat_writeback;
    end

    task automatic access(input we, input [AW-1:0] addr, input [DW-1:0] wd, input [3:0] strb);
        reg [DW-1:0] exp;
        begin
            req_valid <= 1; req_we <= we; req_addr <= addr; req_wdata <= wd; req_wstrb <= strb;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            req_valid <= 0;
            exp = refm[addr[AW-1:2]];
            if (we) begin
                for (b = 0; b < 4; b = b + 1)
                    if (strb[b]) refm[addr[AW-1:2]][8*b +: 8] = wd[8*b +: 8];
                writes = writes + 1;
            end
            @(posedge clk);
            while (!resp_valid) @(posedge clk);
            if (!we) begin
                reads = reads + 1;
                if (resp_rdata !== exp) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH addr %h: got %h exp %h", addr, resp_rdata, exp);
                end
            end
        end
    endtask

    reg [AW-1:0] a;
    integer n_ops = 60000;
    initial begin
        void'($value$plusargs("ops=%d", n_ops));
        for (i = 0; i < (1 << LAW); i = i + 1) begin
            mem[i] = {$urandom, $urandom, $urandom, $urandom};
            for (b = 0; b < WORDS; b = b + 1) refm[i*WORDS + b] = mem[i][b*DW +: DW];
        end
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (i = 0; i < n_ops; i = i + 1) begin
            case ($urandom_range(0, 9))
                0, 1, 2, 3, 4: a = {6'd0, $urandom_range(0, 255)};           // hot region (fits in the cache)
                5, 6, 7:       a = {$urandom_range(0, 15), 2'd1, 6'($urandom)}; // many tags, few sets: conflicts
                default:       a = $urandom;                                  // anywhere
            endcase
            access($urandom_range(0, 2) == 0, a, $urandom, ($urandom_range(0, 3) == 0) ? 4'($urandom) : 4'hF);
            if ($urandom_range(0, 7) == 0) repeat ($urandom_range(1, 3)) @(posedge clk);
        end
        // final sweep: every word must read back correctly through the cache
        for (i = 0; i < NWORDS; i = i + 1) access(1'b0, {i[AW-3:0], 2'b00}, 0, 0);

        $display("dcache: %0d reads, %0d writes, %0d mismatches", reads, writes, errors);
        $display("  hits=%0d misses=%0d write-backs=%0d  hit rate=%.1f%%",
                 hits, misses, wbs, 100.0 * hits / (hits + misses));
        if (errors != 0 || wbs == 0 || misses == 0) $fatal(1, "TEST FAILED");
        $display("TEST PASSED");
        $finish;
    end
endmodule
