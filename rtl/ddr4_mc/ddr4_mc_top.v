`include "ddr4_defines.vh"
//---------------------------------------------------------------------------
// ddr4_mc_top
//
// 2-channel DDR4 memory controller top level. The incoming flat address
// is split as { channel_sel | row | bank | column }; each channel owns an
// independent ddr4_channel (8 banks, full command set, own DDR4
// command/control bus) so the two channels can be active/refreshing/in
// self-refresh completely independently, as on real multi-channel DDR4
// platforms.
//---------------------------------------------------------------------------
module ddr4_mc_top #(
    parameter NUM_CHANNELS = 2,
    parameter ROW_BITS  = 17,
    parameter COL_BITS  = 10,
    parameter BA_BITS   = 3,      // 8 banks/channel
    parameter ADDR_BITS = 17,

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
    parameter tXS   = 432,
    parameter CL    = 16,

    parameter RESET_CYCLES  = 50,
    parameter CKE_CYCLES    = 20,
    parameter MRD_CYCLES    = 8,
    parameter ZQINIT_CYCLES = 64,
    parameter ZQCS_PERIOD   = 100000
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // Flat application address: {chan, row, bank, col}
    input  wire                          app_req,
    input  wire                          app_we,
    input  wire                          app_close_page,
    input  wire [ROW_BITS+BA_BITS+COL_BITS:0] app_addr, // [MSB]=chan sel (1 bit for 2 channels)
    output wire                          app_ack,
    output wire [NUM_CHANNELS-1:0]       app_rvalid, // per-channel: which channel's read data is valid this cycle

    input  wire [NUM_CHANNELS-1:0]       sre_req,   // per-channel self-refresh request
    input  wire [NUM_CHANNELS-1:0]       pd_req,    // per-channel power-down request
    output wire [NUM_CHANNELS-1:0]       init_done,
    output wire [NUM_CHANNELS-1:0]       sr_active,
    output wire [NUM_CHANNELS-1:0]       pdn_active,

    // Per-channel DDR4 command/control bus
    output wire [NUM_CHANNELS-1:0]                  cs_n,
    output wire [NUM_CHANNELS-1:0]                  ras_n,
    output wire [NUM_CHANNELS-1:0]                  cas_n,
    output wire [NUM_CHANNELS-1:0]                  we_n,
    output wire [NUM_CHANNELS*ADDR_BITS-1:0]        addr,
    output wire [NUM_CHANNELS*BA_BITS-1:0]          ba,
    output wire [NUM_CHANNELS-1:0]                  cke,
    output wire [NUM_CHANNELS-1:0]                  odt,
    output wire [NUM_CHANNELS-1:0]                  reset_n
);
    // The address split below uses a single channel-select bit and is only
    // valid for NUM_CHANNELS == 2, matching this controller's requirement.
    wire chan_sel = app_addr[ROW_BITS+BA_BITS+COL_BITS];
    wire [ROW_BITS-1:0] a_row  = app_addr[ROW_BITS+BA_BITS+COL_BITS-1 -: ROW_BITS];
    wire [BA_BITS-1:0]  a_bank = app_addr[COL_BITS +: BA_BITS];
    wire [COL_BITS-1:0] a_col  = app_addr[COL_BITS-1:0];

    wire [NUM_CHANNELS-1:0] ch_req;
    wire [NUM_CHANNELS-1:0] ch_ack;

    genvar c;
    generate
        for (c = 0; c < NUM_CHANNELS; c = c + 1) begin : g_chan
            assign ch_req[c] = app_req && (chan_sel == c[0]);

            ddr4_channel #(
                .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BA_BITS(BA_BITS), .ADDR_BITS(ADDR_BITS),
                .tRCD(tRCD), .tRAS(tRAS), .tRP(tRP), .tWR(tWR), .tRTP(tRTP),
                .tRRD(tRRD), .tFAW(tFAW), .tCCD(tCCD), .tWTR(tWTR),
                .tREFI(tREFI), .tRFC(tRFC), .tXS(tXS), .CL(CL),
                .RESET_CYCLES(RESET_CYCLES), .CKE_CYCLES(CKE_CYCLES),
                .MRD_CYCLES(MRD_CYCLES), .ZQINIT_CYCLES(ZQINIT_CYCLES),
                .ZQCS_PERIOD(ZQCS_PERIOD)
            ) u_channel (
                .clk(clk), .rst_n(rst_n),
                .app_req(ch_req[c]),
                .app_we(app_we),
                .app_close_page(app_close_page),
                .app_bank(a_bank),
                .app_row(a_row),
                .app_col(a_col),
                .app_ack(ch_ack[c]),
                .app_rvalid(app_rvalid[c]),
                .sre_req(sre_req[c]),
                .pd_req(pd_req[c]),
                .init_done(init_done[c]),
                .cs_n(cs_n[c]), .ras_n(ras_n[c]), .cas_n(cas_n[c]), .we_n(we_n[c]),
                .addr(addr[c*ADDR_BITS +: ADDR_BITS]),
                .ba(ba[c*BA_BITS +: BA_BITS]),
                .cke(cke[c]), .odt(odt[c]), .reset_n(reset_n[c]),
                .sr_active(sr_active[c]), .pdn_active(pdn_active[c])
            );
        end
    endgenerate

    // app_req is routed to exactly one channel by ch_req, so exactly one
    // channel can ever assert ch_ack for a given request; OR-ing is safe.
    assign app_ack = |ch_ack;
endmodule
