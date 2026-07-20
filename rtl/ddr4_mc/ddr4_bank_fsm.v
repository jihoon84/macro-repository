`include "ddr4_defines.vh"
//---------------------------------------------------------------------------
// ddr4_bank_fsm
//
// Per-bank timing/state tracker. Enforces tRCD, tRAS, tRP, tWR and tRTP
// for a single DDR4 bank. Supports both the explicit-precharge flow
// (ACT -> RD/WR -> PRE -> ...) and auto-precharge (ACT -> RDA/WRA, which
// self-transitions to PRECHARGING once the write-recovery/read-to-precharge
// time has elapsed, with no separate PRE command needed).
//
// All *_pulse inputs must be asserted for exactly one clock when the
// channel controller issues the corresponding DDR4 command to this bank.
//---------------------------------------------------------------------------
module ddr4_bank_fsm #(
    parameter tRCD    = 14,
    parameter tRAS    = 32,
    parameter tRP     = 14,
    parameter tWR     = 16,
    parameter tRTP    = 8,
    parameter ROW_BITS = 17
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  act_pulse,       // issue ACT this cycle
    input  wire                  rd_pulse,        // issue RD this cycle
    input  wire                  wr_pulse,        // issue WR this cycle
    input  wire                  rd_auto_pulse,   // issue RDA this cycle
    input  wire                  wr_auto_pulse,   // issue WRA this cycle
    input  wire                  pre_pulse,       // issue explicit PRE/PREA this cycle
    input  wire [ROW_BITS-1:0]   act_row,

    output reg  [1:0]            state,           // BANK_IDLE / BANK_ACTIVE / BANK_PRECHARGING
    output wire                  idle,            // bank closed -> ACT legal (subject to tRRD/tFAW upstream)
    output wire                  act_rdy,         // tRCD satisfied -> RD/WR/RDA/WRA legal
    output wire                  pre_rdy,         // tRAS/tWR/tRTP satisfied -> PRE/PREA legal
    output reg  [ROW_BITS-1:0]   open_row
);

    reg [8:0] rcd_cnt, ras_cnt, rp_cnt, wr_cnt, rtp_cnt;
    reg       auto_pre_pending;

    wire rcd_done = (rcd_cnt == 9'd0);
    wire ras_done = (ras_cnt == 9'd0);
    wire rp_done  = (rp_cnt  == 9'd0);
    wire wr_done  = (wr_cnt  == 9'd0);
    wire rtp_done = (rtp_cnt == 9'd0);

    assign idle    = (state == `BANK_IDLE);
    assign act_rdy = (state == `BANK_ACTIVE) && rcd_done;
    assign pre_rdy = (state == `BANK_ACTIVE) && ras_done && wr_done && rtp_done;

    wire auto_pre_ready = auto_pre_pending && ras_done && wr_done && rtp_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= `BANK_IDLE;
            open_row         <= {ROW_BITS{1'b0}};
            rcd_cnt          <= 9'd0;
            ras_cnt          <= 9'd0;
            rp_cnt           <= 9'd0;
            wr_cnt           <= 9'd0;
            rtp_cnt          <= 9'd0;
            auto_pre_pending <= 1'b0;
        end else begin
            if (rcd_cnt != 9'd0) rcd_cnt <= rcd_cnt - 9'd1;
            if (ras_cnt != 9'd0) ras_cnt <= ras_cnt - 9'd1;
            if (rp_cnt  != 9'd0) rp_cnt  <= rp_cnt  - 9'd1;
            if (wr_cnt  != 9'd0) wr_cnt  <= wr_cnt  - 9'd1;
            if (rtp_cnt != 9'd0) rtp_cnt <= rtp_cnt - 9'd1;

            case (state)
                `BANK_IDLE: begin
                    if (act_pulse) begin
                        state    <= `BANK_ACTIVE;
                        open_row <= act_row;
                        rcd_cnt  <= tRCD[8:0] - 9'd1;
                        ras_cnt  <= tRAS[8:0] - 9'd1;
                    end
                end

                `BANK_ACTIVE: begin
                    if (rd_pulse) begin
                        rtp_cnt <= tRTP[8:0] - 9'd1;
                    end else if (wr_pulse) begin
                        wr_cnt  <= tWR[8:0] - 9'd1;
                    end else if (rd_auto_pulse) begin
                        rtp_cnt          <= tRTP[8:0] - 9'd1;
                        auto_pre_pending <= 1'b1;
                    end else if (wr_auto_pulse) begin
                        wr_cnt           <= tWR[8:0] - 9'd1;
                        auto_pre_pending <= 1'b1;
                    end else if (pre_pulse) begin
                        state  <= `BANK_PRECHARGING;
                        rp_cnt <= tRP[8:0] - 9'd1;
                    end else if (auto_pre_ready) begin
                        state            <= `BANK_PRECHARGING;
                        rp_cnt           <= tRP[8:0] - 9'd1;
                        auto_pre_pending <= 1'b0;
                    end
                end

                `BANK_PRECHARGING: begin
                    if (rp_done) state <= `BANK_IDLE;
                end

                default: state <= `BANK_IDLE;
            endcase
        end
    end
endmodule
