// 2-way set-associative write-back data cache with LRU replacement.
//
// CPU side : single outstanding request, valid/ready in, valid out
//            (hit: response in the next cycle)
// Mem side : whole-line read / write-back with req/ack handshake
//
// Miss sequence:  [WRITEBACK dirty victim] -> FILL -> REPLAY (the access hits)
//
// Formal properties live at the bottom under `ifdef FORMAL; they prove by
// k-induction that every read returns the most recently written value
// (see formal/).
module dcache #(
    parameter integer AW    = 32,    // byte address width
    parameter integer DW    = 32,    // word width (multiple of 8)
    parameter integer WORDS = 4,     // words per line (power of two)
    parameter integer SETS  = 64     // sets (power of two)
) (
    input  wire                 clk,
    input  wire                 rst_n,        // synchronous, active low

    input  wire                 req_valid,
    output wire                 req_ready,
    input  wire                 req_we,
    input  wire [AW-1:0]        req_addr,
    input  wire [DW-1:0]        req_wdata,
    input  wire [DW/8-1:0]      req_wstrb,
    output reg                  resp_valid,
    output reg  [DW-1:0]        resp_rdata,

    output wire                 mem_req,
    output wire                 mem_we,
    output wire [AW-$clog2(DW/8)-$clog2(WORDS)-1:0] mem_addr,   // line address {tag, index}
    output wire [WORDS*DW-1:0]  mem_wdata,
    input  wire                 mem_ack,
    input  wire [WORDS*DW-1:0]  mem_rdata,

    output reg                  stat_hit,     // one-cycle pulses
    output reg                  stat_miss,
    output reg                  stat_writeback
`ifdef FORMAL
    ,
    input  wire [AW-$clog2(DW/8)-1:0] f_addr,       // watched word address (any constant)
    input  wire [DW-1:0]              f_mem_word    // backing-store content of that word
`endif
);
    localparam integer BO  = $clog2(DW/8);
    localparam integer WO  = $clog2(WORDS);
    localparam integer IW  = $clog2(SETS);
    localparam integer TW  = AW - BO - WO - IW;
    localparam integer LW  = WORDS * DW;
    localparam integer NSB = DW / 8;

    localparam [1:0] S_IDLE = 2'd0, S_WB = 2'd1, S_FILL = 2'd2, S_REPLAY = 2'd3;

    // storage, entry index = {set, way}
    reg [TW-1:0]     tag_mem  [0:2*SETS-1];
    reg [LW-1:0]     data_mem [0:2*SETS-1];
    reg [2*SETS-1:0] valid;
    reg [2*SETS-1:0] dirty;
    reg [SETS-1:0]   lru;          // way to evict next

    reg [1:0]        state;
    reg [AW-1:0]     addr_q;
    reg              we_q;
    reg [DW-1:0]     wdata_q;
    reg [NSB-1:0]    wstrb_q;
    reg              vway_q;       // victim / refilled way

    // ------------------------------------------------------------ lookup
    wire [AW-1:0] a      = (state == S_IDLE) ? req_addr : addr_q;
    wire [TW-1:0] a_tag  = a[AW-1 -: TW];
    wire [IW-1:0] a_idx  = a[BO+WO +: IW];
    wire [WO-1:0] a_word = a[BO +: WO];

    wire [IW:0] e0 = {a_idx, 1'b0};
    wire [IW:0] e1 = {a_idx, 1'b1};
    wire hit0 = valid[e0] && (tag_mem[e0] == a_tag);
    wire hit1 = valid[e1] && (tag_mem[e1] == a_tag);
    wire hit  = hit0 || hit1;

    wire victim = !valid[e0] ? 1'b0 : !valid[e1] ? 1'b1 : lru[a_idx];

    wire [IW:0] ev = {addr_q[BO+WO +: IW], vway_q};     // victim entry while handling a miss

    assign req_ready = (state == S_IDLE);
    assign mem_req   = (state == S_WB) || (state == S_FILL);
    assign mem_we    = (state == S_WB);
    assign mem_addr  = (state == S_WB) ? {tag_mem[ev], addr_q[BO+WO +: IW]} : addr_q[AW-1 : BO+WO];
    assign mem_wdata = data_mem[ev];

    // ------------------------------------------------------------ access
    wire        acc_en   = (state == S_IDLE && req_valid && hit) || (state == S_REPLAY);
    wire        acc_way  = (state == S_REPLAY) ? vway_q : hit1;
    wire        acc_we   = (state == S_REPLAY) ? we_q    : req_we;
    wire [DW-1:0]  acc_wdata = (state == S_REPLAY) ? wdata_q : req_wdata;
    wire [NSB-1:0] acc_wstrb = (state == S_REPLAY) ? wstrb_q : req_wstrb;
    wire [IW:0] ea       = {a_idx, acc_way};
    wire [DW-1:0] cur_word = data_mem[ea][a_word*DW +: DW];

    reg [DW-1:0] new_word;
    integer b;
    always @* begin
        new_word = cur_word;
        for (b = 0; b < NSB; b = b + 1)
            if (acc_wstrb[b]) new_word[8*b +: 8] = acc_wdata[8*b +: 8];
    end

    always @(posedge clk) begin
        resp_valid     <= 1'b0;
        stat_hit       <= 1'b0;
        stat_miss      <= 1'b0;
        stat_writeback <= 1'b0;

        if (acc_en) begin
            resp_valid <= 1'b1;
            lru[a_idx] <= ~acc_way;
            if (acc_we) begin
                data_mem[ea][a_word*DW +: DW] <= new_word;
                dirty[ea] <= 1'b1;
            end else begin
                resp_rdata <= cur_word;
            end
        end

        case (state)
            S_IDLE: if (req_valid) begin
                addr_q  <= req_addr;
                we_q    <= req_we;
                wdata_q <= req_wdata;
                wstrb_q <= req_wstrb;
                if (hit) begin
                    stat_hit <= 1'b1;
                end else begin
                    stat_miss <= 1'b1;
                    vway_q    <= victim;
                    state     <= (valid[{a_idx, victim}] && dirty[{a_idx, victim}]) ? S_WB : S_FILL;
                end
            end

            S_WB: if (mem_ack) begin
                dirty[ev]      <= 1'b0;
                stat_writeback <= 1'b1;
                state          <= S_FILL;
            end

            S_FILL: if (mem_ack) begin
                data_mem[ev] <= mem_rdata;
                tag_mem[ev]  <= addr_q[AW-1 -: TW];
                valid[ev]    <= 1'b1;
                dirty[ev]    <= 1'b0;
                state        <= S_REPLAY;
            end

            default: state <= S_IDLE;     // S_REPLAY
        endcase

        if (!rst_n) begin
            state      <= S_IDLE;
            valid      <= {2*SETS{1'b0}};
            dirty      <= {2*SETS{1'b0}};
            lru        <= {SETS{1'b0}};
            resp_valid <= 1'b0;
            stat_hit   <= 1'b0; stat_miss <= 1'b0; stat_writeback <= 1'b0;
        end
    end

`ifdef FORMAL
    // =====================================================================
    // Formal model: watch one arbitrary word (f_addr). f_data is its
    // architectural value - what a memory without a cache would hold.
    // =====================================================================
    wire [TW-1:0] f_tag  = f_addr[AW-BO-1 -: TW];
    wire [IW-1:0] f_idx  = f_addr[WO +: IW];
    wire [WO-1:0] f_word = f_addr[WO-1:0];
    wire [IW:0]   f_e0   = {f_idx, 1'b0};
    wire [IW:0]   f_e1   = {f_idx, 1'b1};
    wire f_c0 = valid[f_e0] && (tag_mem[f_e0] == f_tag);     // watched line cached in way 0 / 1
    wire f_c1 = valid[f_e1] && (tag_mem[f_e1] == f_tag);
    wire [DW-1:0] f_cw0 = data_mem[f_e0][f_word*DW +: DW];
    wire [DW-1:0] f_cw1 = data_mem[f_e1][f_word*DW +: DW];

    reg [DW-1:0] f_data;
    reg          f_past_valid = 1'b0;
    wire         f_acc_watched = acc_en && (a[AW-1:BO] == f_addr);

    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        if (!rst_n)
            f_data <= f_mem_word;        // reset drops the cache: memory is the truth again
        else if (f_acc_watched && acc_we)
            for (b = 0; b < NSB; b = b + 1)
                if (acc_wstrb[b]) f_data[8*b +: 8] <= acc_wdata[8*b +: 8];
    end

    // Every trace starts with a reset cycle.
    initial assume (!rst_n);

    always @(posedge clk) if (rst_n) begin
        // ---- the property we care about -----------------------------
        // A read of the watched word returns its architectural value.
        if (resp_valid && !we_q && (addr_q[AW-1:BO] == f_addr))
            assert (resp_rdata == f_data);

        // ---- inductive invariants that make it provable ---------------
        // the watched word lives in exactly one place
        assert (!(f_c0 && f_c1));
        if (f_c0) assert (f_cw0 == f_data);
        if (f_c1) assert (f_cw1 == f_data);
        if (!f_c0 && !f_c1)        assert (f_mem_word == f_data);   // not cached: memory is current
        if (f_c0 && !dirty[f_e0])  assert (f_mem_word == f_data);   // cached clean: memory is current
        if (f_c1 && !dirty[f_e1])  assert (f_mem_word == f_data);
        // miss-handling state machine consistency
        if (state == S_WB || state == S_FILL) assert (!hit);
        if (state == S_WB)     assert (valid[ev] && dirty[ev]);
        if (state == S_FILL)   assert (!(valid[ev] && dirty[ev]));
        if (state == S_REPLAY) assert (valid[ev] && tag_mem[ev] == addr_q[AW-1 -: TW]);
        // a response is only produced one cycle after an access
        if (f_past_valid && resp_valid) assert ($past(acc_en));
    end

    // no set ever holds the same tag twice
    genvar gs;
    generate
        for (gs = 0; gs < SETS; gs = gs + 1) begin : g_nodup
            always @(posedge clk) if (rst_n)
                assert (!(valid[2*gs] && valid[2*gs+1] && tag_mem[2*gs] == tag_mem[2*gs+1]));
        end
    endgenerate

    // ---- reachability: prove the interesting scenarios actually happen
    reg f_seen_wr = 1'b0;         // watched word was written through the cache ...
    reg f_seen_wb = 1'b0;         // ... and its dirty line was later evicted to memory
    always @(posedge clk) begin
        if (!rst_n) begin
            f_seen_wr <= 1'b0;
            f_seen_wb <= 1'b0;
        end else begin
            if (f_acc_watched && acc_we) f_seen_wr <= 1'b1;
            if (f_seen_wr && state == S_WB && mem_ack
                && tag_mem[ev] == f_tag && addr_q[BO+WO +: IW] == f_idx)
                f_seen_wb <= 1'b1;
            cover (stat_writeback);
            // write -> evict (write-back) -> miss + refill -> read the data back
            cover (f_seen_wb && $past(state) == S_REPLAY && resp_valid && !we_q
                   && addr_q[AW-1:BO] == f_addr);
        end
    end
`endif
endmodule
