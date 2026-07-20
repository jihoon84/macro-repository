`include "ddr4_defines.vh"
//---------------------------------------------------------------------------
// ddr4_cmd_encoder
//
// Pure combinational translation from an internal CMD_* opcode into the
// classic CS_n/RAS_n/CAS_n/WE_n + address truth table shared by SDR/DDR/
// DDR2/DDR3/DDR4 SDRAM. A10 carries the auto-precharge (RD/WR) or
// all-bank (PRE) qualifier per JEDEC JESD79-4.
//---------------------------------------------------------------------------
module ddr4_cmd_encoder #(
    parameter ADDR_BITS = 17,   // wide enough to carry a full row address
    parameter BA_BITS   = 3     // 3 bits -> 8 banks per channel
)(
    input  wire [3:0]           cmd,
    input  wire [BA_BITS-1:0]   bank_id,
    input  wire [ADDR_BITS-1:0] addr_in,      // row addr (ACT) or column addr (RD/WR)
    input  wire                 a10_qualifier,// auto-precharge / precharge-all bit
    input  wire [ADDR_BITS-1:0] mrs_payload,  // mode register value for MRS

    output reg                  cs_n,
    output reg                  ras_n,
    output reg                  cas_n,
    output reg                  we_n,
    output reg  [ADDR_BITS-1:0] addr,
    output reg  [BA_BITS-1:0]   ba
);
    always @(*) begin
        cs_n  = 1'b1;   // default: deselected (DES / NOP-equivalent)
        ras_n = 1'b1;
        cas_n = 1'b1;
        we_n  = 1'b1;
        addr  = {ADDR_BITS{1'b0}};
        ba    = bank_id;

        case (cmd)
            `CMD_MRS: begin
                cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b0; we_n = 1'b0;
                addr = mrs_payload;
            end

            `CMD_REF, `CMD_SRE: begin
                // SRE reuses the REF encoding; self-refresh entry is
                // distinguished by CKE being dropped on the following edge
                // (handled by the caller, not by this encoder).
                cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b0; we_n = 1'b1;
            end

            `CMD_PRE: begin
                cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b1; we_n = 1'b0;
                addr[10] = 1'b0;
            end

            `CMD_PREA: begin
                cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b1; we_n = 1'b0;
                addr[10] = 1'b1;
            end

            `CMD_ACT: begin
                cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b1; we_n = 1'b1;
                addr = addr_in;                    // row address
            end

            `CMD_WR: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b0;
                addr = addr_in; addr[10] = 1'b0;
            end

            `CMD_WRA: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b0;
                addr = addr_in; addr[10] = 1'b1;
            end

            `CMD_RD: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b1;
                addr = addr_in; addr[10] = 1'b0;
            end

            `CMD_RDA: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b1;
                addr = addr_in; addr[10] = 1'b1;
            end

            `CMD_ZQCL: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b0;
                addr[10] = 1'b1;
            end

            `CMD_ZQCS: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b0;
                addr[10] = 1'b0;
            end

            `CMD_NOP: begin
                cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b1;
            end

            `CMD_DES, `CMD_SRX, `CMD_PDE: begin
                // DES; SRX/PDE/PDX are realized purely through the CKE
                // pin transition applied alongside this deselect cycle.
                cs_n = 1'b1;
            end

            default: cs_n = 1'b1;
        endcase

        // a10_qualifier lets the caller drive PREA-vs-PRE / RDA-vs-RD /
        // WRA-vs-WR through a single opcode plus a qualifier bit instead
        // of needing every combination pre-selected upstream.
        if (cmd == `CMD_PRE || cmd == `CMD_PREA ||
            cmd == `CMD_RD  || cmd == `CMD_RDA  ||
            cmd == `CMD_WR  || cmd == `CMD_WRA)
            addr[10] = a10_qualifier;
    end
endmodule
