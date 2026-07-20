`include "ddr4_defines.vh"
//---------------------------------------------------------------------------
// ddr4_channel
//
// Single-channel DDR4 controller: JEDEC init sequence, 8 independently
// timed banks (open-page, with optional per-request auto-precharge),
// tRRD/tFAW/tCCD/tWTR enforcement across banks, periodic refresh with
// JEDEC 8x deferral credit, self-refresh entry/exit, and power-down
// entry/exit. Issues at most one DDR4 command per clock, matching the
// single command/address bus of a real DDR4 channel.
//
// Front-end is intentionally a minimal single-outstanding request/ack
// interface -- enough to demonstrate every DDR4 command legally and in
// the right order. A production controller would replace this with a
// multi-entry, reorderable command queue; the bank/refresh/timing engine
// below does not change to support that.
//
// DQ/DQS training, write-leveling and the data path itself belong to the
// PHY (DFI or vendor hard IP) and are out of scope here: this module only
// drives the command/address/control bus and a CL-aligned read-data-valid
// strobe that a PHY would pair with the actual DQ bus.
//---------------------------------------------------------------------------
module ddr4_channel #(
    parameter ROW_BITS  = 17,
    parameter COL_BITS  = 10,
    parameter BA_BITS   = 3,          // 3 bits -> 8 banks/channel
    parameter ADDR_BITS = 17,

    // DRAM timing, in controller-clock cycles -- tune to the target DDR4
    // speed bin per JESD79-4; defaults are roughly DDR4-2400-ish (CL=16).
    parameter tRCD  = 14,
    parameter tRAS  = 32,
    parameter tRP   = 14,
    parameter tWR   = 16,
    parameter tRTP  = 8,
    parameter tRRD  = 6,
    parameter tFAW  = 26,
    parameter tCCD  = 6,
    parameter tWTR  = 8,
    parameter tREFI = 1560,
    parameter tRFC  = 420,
    parameter tXS   = 432,            // self-refresh exit to valid command
    parameter CL    = 16,

    // Mode register payloads -- program per JESD79-4 Table "Mode Register
    // Definition" for the chosen speed bin; left as 0 by default.
    parameter [ADDR_BITS-1:0] MR0_VAL = {ADDR_BITS{1'b0}},
    parameter [ADDR_BITS-1:0] MR1_VAL = {ADDR_BITS{1'b0}},
    parameter [ADDR_BITS-1:0] MR2_VAL = {ADDR_BITS{1'b0}},
    parameter [ADDR_BITS-1:0] MR3_VAL = {ADDR_BITS{1'b0}},

    // Init timing -- shrink for simulation; use datasheet values (tPW_RESET_L
    // ~200us, tXPR, tMRD, tZQinit) for silicon.
    parameter RESET_CYCLES  = 50,
    parameter CKE_CYCLES    = 20,
    parameter MRD_CYCLES    = 8,
    parameter ZQINIT_CYCLES = 64,
    parameter ZQCS_PERIOD   = 100000
)(
    input  wire                    clk,
    input  wire                    rst_n,        // controller-side reset

    input  wire                    app_req,
    input  wire                    app_we,
    input  wire                    app_close_page,
    input  wire [BA_BITS-1:0]      app_bank,
    input  wire [ROW_BITS-1:0]     app_row,
    input  wire [COL_BITS-1:0]     app_col,
    output wire                    app_ack,
    output reg                     app_rvalid,

    input  wire                    sre_req,
    input  wire                    pd_req,
    output wire                    init_done,

    output wire                    cs_n,
    output wire                    ras_n,
    output wire                    cas_n,
    output wire                    we_n,
    output wire [ADDR_BITS-1:0]    addr,
    output wire [BA_BITS-1:0]      ba,
    output reg                     cke,
    output reg                     odt,
    output reg                     reset_n,
    output wire                    sr_active,   // in self-refresh
    output wire                    pdn_active   // in power-down
);
    assign sr_active  = sre_active;
    assign pdn_active = pd_active;

    localparam NUM_BANKS = (1 << BA_BITS);

    //-----------------------------------------------------------------
    // Front-end request register (single outstanding transaction).
    // Declared ahead of the bank generate block below since it is wired
    // directly into each ddr4_bank_fsm instance's act_row port.
    //-----------------------------------------------------------------
    reg                  busy;
    reg                  targ_we, targ_close;
    reg [BA_BITS-1:0]    targ_bank;
    reg [ROW_BITS-1:0]   targ_row;
    reg [COL_BITS-1:0]   targ_col;

    //-----------------------------------------------------------------
    // Per-bank timing FSMs
    //-----------------------------------------------------------------
    wire                bk_idle    [0:NUM_BANKS-1];
    wire                bk_act_rdy [0:NUM_BANKS-1];
    wire                bk_pre_rdy [0:NUM_BANKS-1];
    wire [ROW_BITS-1:0] bk_open_row[0:NUM_BANKS-1];
    reg                 bk_act_pulse    [0:NUM_BANKS-1];
    reg                 bk_rd_pulse     [0:NUM_BANKS-1];
    reg                 bk_wr_pulse     [0:NUM_BANKS-1];
    reg                 bk_rd_auto_pulse[0:NUM_BANKS-1];
    reg                 bk_wr_auto_pulse[0:NUM_BANKS-1];
    reg                 bk_pre_pulse    [0:NUM_BANKS-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_BANKS; gi = gi + 1) begin : g_banks
            ddr4_bank_fsm #(
                .tRCD(tRCD), .tRAS(tRAS), .tRP(tRP), .tWR(tWR), .tRTP(tRTP),
                .ROW_BITS(ROW_BITS)
            ) u_bank (
                .clk(clk), .rst_n(rst_n),
                .act_pulse(bk_act_pulse[gi]),
                .rd_pulse(bk_rd_pulse[gi]),
                .wr_pulse(bk_wr_pulse[gi]),
                .rd_auto_pulse(bk_rd_auto_pulse[gi]),
                .wr_auto_pulse(bk_wr_auto_pulse[gi]),
                .pre_pulse(bk_pre_pulse[gi]),
                .act_row(targ_row), // latched target row, NOT the live app_row
                                    // input (which may already reflect a
                                    // later, not-yet-accepted request by the
                                    // time this ACT actually issues)
                .state(), // unused externally
                .idle(bk_idle[gi]),
                .act_rdy(bk_act_rdy[gi]),
                .pre_rdy(bk_pre_rdy[gi]),
                .open_row(bk_open_row[gi])
            );
        end
    endgenerate

    // Verilog-2001 has no reduction-and over an unpacked array, so these
    // are built explicitly from the per-bank idle/pre_rdy flags below.
    reg all_idle_r, pre_rdy_all_r;
    integer bi;
    always @(*) begin
        all_idle_r    = 1'b1;
        pre_rdy_all_r = 1'b1;
        for (bi = 0; bi < NUM_BANKS; bi = bi + 1) begin
            if (!bk_idle[bi]) all_idle_r = 1'b0;
            if (!(bk_idle[bi] || bk_pre_rdy[bi])) pre_rdy_all_r = 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // Refresh scheduler
    //-----------------------------------------------------------------
    wire ref_req, ref_urgent, rfc_busy;
    reg  ref_issued;
    ddr4_refresh_ctrl #(.tREFI(tREFI), .tRFC(tRFC)) u_refresh (
        .clk(clk), .rst_n(rst_n),
        .ref_issued(ref_issued),
        .ref_req(ref_req), .ref_urgent(ref_urgent), .rfc_busy(rfc_busy)
    );

    //-----------------------------------------------------------------
    // Channel-wide inter-command timing: tRRD/tFAW (activate spacing)
    // and tCCD/tWTR (CAS spacing)
    //-----------------------------------------------------------------
    reg [8:0] rrd_cnt;
    reg [8:0] faw_c0, faw_c1, faw_c2, faw_c3;
    reg [8:0] ccd_cnt;
    reg [8:0] wtr_cnt;
    wire rrd_ok        = (rrd_cnt == 9'd0);
    wire faw_slot_free  = (faw_c0 == 9'd0) || (faw_c1 == 9'd0) || (faw_c2 == 9'd0) || (faw_c3 == 9'd0);
    wire act_global_ok  = rrd_ok && faw_slot_free;
    wire ccd_ok         = (ccd_cnt == 9'd0);
    wire wtr_ok          = (wtr_cnt == 9'd0);

    // accept_new (below) already encodes the exact set of conditions under
    // which a new request is latched -- app_ack must track it exactly, not
    // a separately re-derived condition that could drift out of sync.
    assign app_ack = accept_new;

    //-----------------------------------------------------------------
    // Init / self-refresh / power-down control FSM
    //-----------------------------------------------------------------
    reg [3:0]  ch_state;
    reg [31:0] timer;
    reg [1:0]  mr_idx;
    reg        sre_active, pd_active;
    localparam SR_PRE = 2'd0, SR_HOLD = 2'd1, SR_XWAIT = 2'd2;
    reg [1:0]  sr_sub;

    assign init_done = (ch_state != `CH_S_RESET) && (ch_state != `CH_S_INIT_CKE) &&
                        (ch_state != `CH_S_INIT_MRS) && (ch_state != `CH_S_INIT_ZQCL);

    // Periodic ZQCS request
    reg [31:0] zqcs_cnt;
    reg        zqcs_due;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zqcs_cnt <= 32'd0;
            zqcs_due <= 1'b0;
        end else if (init_done) begin
            if (zqcs_cnt == ZQCS_PERIOD - 1) begin
                zqcs_cnt <= 32'd0;
                zqcs_due <= 1'b1;
            end else begin
                zqcs_cnt <= zqcs_cnt + 32'd1;
            end
            if (ch_state == `CH_S_CTRL && !busy && zqcs_due) zqcs_due <= 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // Combinational command decision
    //-----------------------------------------------------------------
    reg [3:0]            cmd_sel;
    reg [BA_BITS-1:0]     bank_sel;
    reg [ADDR_BITS-1:0]   addr_field_sel;
    reg                   a10_sel;
    reg [ADDR_BITS-1:0]   mrs_payload_sel;
    reg                   accept_new;
    reg                   rd_cmd_issued;

    always @(*) begin
        cmd_sel         = `CMD_NOP;
        bank_sel        = {BA_BITS{1'b0}};
        addr_field_sel  = {ADDR_BITS{1'b0}};
        a10_sel         = 1'b0;
        mrs_payload_sel = {ADDR_BITS{1'b0}};
        accept_new      = 1'b0;
        ref_issued      = 1'b0;
        rd_cmd_issued   = 1'b0;

        for (bi = 0; bi < NUM_BANKS; bi = bi + 1) begin
            bk_act_pulse[bi]     = 1'b0;
            bk_rd_pulse[bi]      = 1'b0;
            bk_wr_pulse[bi]      = 1'b0;
            bk_rd_auto_pulse[bi] = 1'b0;
            bk_wr_auto_pulse[bi] = 1'b0;
            bk_pre_pulse[bi]     = 1'b0;
        end

        case (ch_state)
            `CH_S_RESET: begin
                cmd_sel = `CMD_DES;
            end

            `CH_S_INIT_CKE: begin
                cmd_sel = `CMD_DES;
            end

            `CH_S_INIT_MRS: begin
                if (timer == 32'd0) begin
                    cmd_sel = `CMD_MRS;
                    // MR0-MR3 are selected via BA1:BA0 (mr_idx) with all
                    // higher bank-address bits (bank-group-equivalent) 0.
                    bank_sel = {{(BA_BITS-2){1'b0}}, mr_idx};
                    case (mr_idx)
                        2'd0: mrs_payload_sel = MR0_VAL;
                        2'd1: mrs_payload_sel = MR1_VAL;
                        2'd2: mrs_payload_sel = MR2_VAL;
                        default: mrs_payload_sel = MR3_VAL;
                    endcase
                end else begin
                    cmd_sel = `CMD_DES;
                end
            end

            `CH_S_INIT_ZQCL: begin
                if (timer == 32'd0) begin
                    cmd_sel = `CMD_ZQCL;
                    a10_sel = 1'b1;
                end else begin
                    cmd_sel = `CMD_DES;
                end
            end

            `CH_S_SELFREF: begin
                case (sr_sub)
                    SR_PRE: begin
                        if (rfc_busy) begin
                            cmd_sel = `CMD_DES; // still recovering from a prior REF
                        end else if (!all_idle_r) begin
                            if (pre_rdy_all_r) begin
                                cmd_sel = `CMD_PREA;
                                a10_sel = 1'b1;
                                for (bi = 0; bi < NUM_BANKS; bi = bi + 1)
                                    bk_pre_pulse[bi] = !bk_idle[bi];
                            end else begin
                                cmd_sel = `CMD_DES;
                            end
                        end else begin
                            cmd_sel = `CMD_SRE; // REF encoding; CKE dropped next edge
                            ref_issued = 1'b1;
                        end
                    end
                    SR_HOLD: cmd_sel = `CMD_DES; // CKE held low: true self-refresh
                    SR_XWAIT: cmd_sel = `CMD_DES;
                    default: cmd_sel = `CMD_DES;
                endcase
            end

            `CH_S_PWRDN: begin
                cmd_sel = `CMD_DES; // power-down entry/exit is a pure CKE transition
            end

            `CH_S_CTRL: begin
                // The whole device is busy recovering for tRFC after a REF;
                // no other command (including ACT/RD/WR) may be issued
                // until it clears, and back-to-back REFs must respect it too.
                if (rfc_busy) begin
                    // NOP (default), wait for tRFC to elapse
                end else if (ref_urgent || (ref_req && !busy)) begin
                    if (all_idle_r) begin
                        cmd_sel = `CMD_REF;
                        ref_issued = 1'b1;
                    end else if (pre_rdy_all_r) begin
                        cmd_sel = `CMD_PREA;
                        a10_sel = 1'b1;
                        for (bi = 0; bi < NUM_BANKS; bi = bi + 1)
                            bk_pre_pulse[bi] = !bk_idle[bi];
                    end
                    // else: NOP, wait for banks to reach a preemptible state
                end else if (!busy && zqcs_due) begin
                    cmd_sel = `CMD_ZQCS;
                    a10_sel = 1'b0;
                end else if (busy) begin
                    bank_sel = targ_bank;
                    if (bk_idle[targ_bank]) begin
                        if (act_global_ok) begin
                            cmd_sel        = `CMD_ACT;
                            addr_field_sel = targ_row;
                            bk_act_pulse[targ_bank] = 1'b1;
                        end
                    end else if (bk_open_row[targ_bank] == targ_row) begin
                        if (bk_act_rdy[targ_bank] && ccd_ok && (!targ_we || wtr_ok)) begin
                            addr_field_sel = targ_col;
                            a10_sel        = targ_close;
                            if (targ_we) begin
                                cmd_sel = targ_close ? `CMD_WRA : `CMD_WR;
                                if (targ_close) bk_wr_auto_pulse[targ_bank] = 1'b1;
                                else            bk_wr_pulse[targ_bank]      = 1'b1;
                            end else begin
                                cmd_sel = targ_close ? `CMD_RDA : `CMD_RD;
                                if (targ_close) bk_rd_auto_pulse[targ_bank] = 1'b1;
                                else            bk_rd_pulse[targ_bank]      = 1'b1;
                                rd_cmd_issued = 1'b1;
                            end
                        end
                    end else begin
                        // wrong row open: close it first (row-buffer miss)
                        if (bk_pre_rdy[targ_bank]) begin
                            cmd_sel = `CMD_PRE;
                            a10_sel = 1'b0;
                            bk_pre_pulse[targ_bank] = 1'b1;
                        end
                    end
                end else if (app_req) begin
                    accept_new = 1'b1;
                end
            end

            default: cmd_sel = `CMD_DES;
        endcase
    end

    //-----------------------------------------------------------------
    // Command encoder (pin-level truth table)
    //-----------------------------------------------------------------
    ddr4_cmd_encoder #(.ADDR_BITS(ADDR_BITS), .BA_BITS(BA_BITS)) u_enc (
        .cmd(cmd_sel),
        .bank_id(bank_sel),
        .addr_in(addr_field_sel),
        .a10_qualifier(a10_sel),
        .mrs_payload(mrs_payload_sel),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(addr), .ba(ba)
    );

    //-----------------------------------------------------------------
    // Sequential: init sequence, self-refresh/power-down control,
    // request register, tRRD/tFAW/tCCD/tWTR counters, CKE/ODT/RESET#.
    //-----------------------------------------------------------------
    reg [31:0] rd_valid_sr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch_state    <= `CH_S_RESET;
            timer       <= RESET_CYCLES;
            mr_idx      <= 2'd0;
            cke         <= 1'b0;
            odt         <= 1'b0;
            reset_n     <= 1'b0;
            busy        <= 1'b0;
            targ_we     <= 1'b0;
            targ_close  <= 1'b0;
            targ_bank   <= {BA_BITS{1'b0}};
            targ_row    <= {ROW_BITS{1'b0}};
            targ_col    <= {COL_BITS{1'b0}};
            sre_active  <= 1'b0;
            pd_active   <= 1'b0;
            sr_sub      <= SR_PRE;
            rrd_cnt <= 9'd0; faw_c0 <= 9'd0; faw_c1 <= 9'd0; faw_c2 <= 9'd0; faw_c3 <= 9'd0;
            ccd_cnt <= 9'd0; wtr_cnt <= 9'd0;
            rd_valid_sr <= 32'd0;
            app_rvalid  <= 1'b0;
        end else begin
            // channel-wide spacing counters
            if (rrd_cnt != 9'd0) rrd_cnt <= rrd_cnt - 9'd1;
            if (faw_c0  != 9'd0) faw_c0  <= faw_c0  - 9'd1;
            if (faw_c1  != 9'd0) faw_c1  <= faw_c1  - 9'd1;
            if (faw_c2  != 9'd0) faw_c2  <= faw_c2  - 9'd1;
            if (faw_c3  != 9'd0) faw_c3  <= faw_c3  - 9'd1;
            if (ccd_cnt != 9'd0) ccd_cnt <= ccd_cnt - 9'd1;
            if (wtr_cnt != 9'd0) wtr_cnt <= wtr_cnt - 9'd1;

            if (cmd_sel == `CMD_ACT) begin
                rrd_cnt <= tRRD[8:0] - 9'd1;
                if      (faw_c0 == 9'd0) faw_c0 <= tFAW[8:0] - 9'd1;
                else if (faw_c1 == 9'd0) faw_c1 <= tFAW[8:0] - 9'd1;
                else if (faw_c2 == 9'd0) faw_c2 <= tFAW[8:0] - 9'd1;
                else                     faw_c3 <= tFAW[8:0] - 9'd1;
            end
            if (cmd_sel == `CMD_RD || cmd_sel == `CMD_RDA ||
                cmd_sel == `CMD_WR || cmd_sel == `CMD_WRA) begin
                ccd_cnt <= tCCD[8:0] - 9'd1;
            end
            if (cmd_sel == `CMD_WR || cmd_sel == `CMD_WRA) begin
                wtr_cnt <= tWTR[8:0] - 9'd1;
            end

            // CL-aligned read-data-valid strobe for the PHY/data path
            // (assumes CL >= 2, true for every real DDR4 speed bin)
            rd_valid_sr <= {rd_valid_sr[30:0], rd_cmd_issued};
            app_rvalid  <= rd_valid_sr[CL-2];

            // request register
            if (accept_new) begin
                busy       <= 1'b1;
                targ_we    <= app_we;
                targ_close <= app_close_page;
                targ_bank  <= app_bank;
                targ_row   <= app_row;
                targ_col   <= app_col;
            end else if (busy && (cmd_sel == `CMD_RD || cmd_sel == `CMD_RDA ||
                                   cmd_sel == `CMD_WR || cmd_sel == `CMD_WRA)) begin
                busy <= 1'b0;
            end

            case (ch_state)
                `CH_S_RESET: begin
                    reset_n <= 1'b0;
                    cke     <= 1'b0;
                    if (timer == 32'd0) begin
                        ch_state <= `CH_S_INIT_CKE;
                        timer    <= CKE_CYCLES;
                        reset_n  <= 1'b1;
                    end else begin
                        timer <= timer - 32'd1;
                    end
                end

                `CH_S_INIT_CKE: begin
                    if (timer == 32'd0) begin
                        cke      <= 1'b1;
                        ch_state <= `CH_S_INIT_MRS;
                        timer    <= MRD_CYCLES;
                        mr_idx   <= 2'd0;
                    end else begin
                        timer <= timer - 32'd1;
                    end
                end

                `CH_S_INIT_MRS: begin
                    if (timer == 32'd0) begin
                        if (mr_idx == 2'd3) begin
                            ch_state <= `CH_S_INIT_ZQCL;
                            timer    <= ZQINIT_CYCLES;
                        end else begin
                            mr_idx <= mr_idx + 2'd1;
                            timer  <= MRD_CYCLES;
                        end
                    end else begin
                        timer <= timer - 32'd1;
                    end
                end

                `CH_S_INIT_ZQCL: begin
                    if (timer == 32'd0) begin
                        ch_state <= `CH_S_CTRL;
                    end else begin
                        timer <= timer - 32'd1;
                    end
                end

                `CH_S_CTRL: begin
                    odt <= busy; // simplistic: terminate while a transaction is in flight
                    // Only enter self-refresh/power-down on a cycle where the
                    // command bus is otherwise idle (NOP) and no tRFC
                    // recovery is in flight, so entry never collides with a
                    // REF/PREA/ZQCS issued the same cycle or cuts a REF's
                    // recovery window short.
                    if (sre_req && !busy && !ref_req && !rfc_busy && cmd_sel == `CMD_NOP) begin
                        ch_state   <= `CH_S_SELFREF;
                        sr_sub     <= SR_PRE;
                        sre_active <= 1'b1;
                    end else if (pd_req && !busy && !rfc_busy && cmd_sel == `CMD_NOP) begin
                        ch_state  <= `CH_S_PWRDN;
                        cke       <= 1'b0;   // PDE: CKE falling edge
                        pd_active <= 1'b1;
                    end
                end

                `CH_S_SELFREF: begin
                    case (sr_sub)
                        SR_PRE: begin
                            if (all_idle_r) begin
                                cke    <= 1'b0;  // SRE: CKE falling edge, same cycle as REF
                                sr_sub <= SR_HOLD;
                            end
                        end
                        SR_HOLD: begin
                            if (!sre_req) begin
                                cke    <= 1'b1;  // SRX: CKE rising edge
                                sr_sub <= SR_XWAIT;
                                timer  <= tXS;
                            end
                        end
                        SR_XWAIT: begin
                            if (timer == 32'd0) begin
                                ch_state   <= `CH_S_CTRL;
                                sre_active <= 1'b0;
                            end else begin
                                timer <= timer - 32'd1;
                            end
                        end
                        default: sr_sub <= SR_PRE;
                    endcase
                end

                `CH_S_PWRDN: begin
                    if (!pd_req) begin
                        cke       <= 1'b1;  // PDX: CKE rising edge
                        ch_state  <= `CH_S_CTRL;
                        pd_active <= 1'b0;
                    end
                end

                default: ch_state <= `CH_S_RESET;
            endcase
        end
    end
endmodule
