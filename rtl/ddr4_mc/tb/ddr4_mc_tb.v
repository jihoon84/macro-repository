`timescale 1ns/1ps
`include "ddr4_defines.vh"
//---------------------------------------------------------------------------
// ddr4_mc_tb
//
// Smoke test for ddr4_mc_top: walks through JEDEC init (RESET# / CKE /
// MRS0-3 / ZQCL), an open-page write+read hit, a row-buffer-miss (PRE+ACT),
// a close-page access (WRA/RDA), a forced refresh, self-refresh entry/exit,
// and power-down entry/exit -- i.e. every command in ddr4_defines.vh gets
// exercised at least once. Decodes and prints channel-0's command bus each
// cycle so the sequence can be eyeballed in the log or a waveform viewer.
//
// Init/refresh timing parameters are shrunk drastically vs. real silicon
// purely so the sequence completes in a few thousand cycles of simulation.
//---------------------------------------------------------------------------
module ddr4_mc_tb;

    localparam ROW_BITS = 17, COL_BITS = 10, BA_BITS = 3, ADDR_BITS = 17;

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk; // 500 MHz controller clock (arbitrary for sim)

    reg                                   app_req = 0;
    reg                                   app_we  = 0;
    reg                                   app_close_page = 0;
    reg  [ROW_BITS+BA_BITS+COL_BITS:0]    app_addr = 0;
    wire                                  app_ack;
    wire [1:0]                            app_rvalid;

    reg  [1:0] sre_req = 2'b00;
    reg  [1:0] pd_req  = 2'b00;
    wire [1:0] init_done, sr_active, pdn_active;

    wire [1:0] cs_n, ras_n, cas_n, we_n, cke, odt, reset_n;
    wire [2*ADDR_BITS-1:0] addr;
    wire [2*BA_BITS-1:0]   ba;

    ddr4_mc_top #(
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BA_BITS(BA_BITS), .ADDR_BITS(ADDR_BITS),
        .tRCD(4), .tRAS(8), .tRP(4), .tWR(4), .tRTP(3),
        .tRRD(2), .tFAW(8), .tCCD(2), .tWTR(3),
        .tREFI(300), .tRFC(20), .tXS(15), .CL(4),
        .RESET_CYCLES(10), .CKE_CYCLES(5), .MRD_CYCLES(3), .ZQINIT_CYCLES(8),
        .ZQCS_PERIOD(5000)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .app_req(app_req), .app_we(app_we), .app_close_page(app_close_page),
        .app_addr(app_addr), .app_ack(app_ack), .app_rvalid(app_rvalid),
        .sre_req(sre_req), .pd_req(pd_req),
        .init_done(init_done), .sr_active(sr_active), .pdn_active(pdn_active),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(addr), .ba(ba), .cke(cke), .odt(odt), .reset_n(reset_n)
    );

    // ---- command-bus decode/trace for channel 0 -------------------------
    function [63:0] cmd_name;
        input cs_n_i, ras_n_i, cas_n_i, we_n_i, a10_i, cke_i;
        begin
            if (!cke_i)                                      cmd_name = "PDN/SREF";
            else if (cs_n_i)                                  cmd_name = "DES";
            else if (!ras_n_i && !cas_n_i && !we_n_i)         cmd_name = "MRS";
            else if (!ras_n_i && !cas_n_i &&  we_n_i)         cmd_name = "REF";
            else if (!ras_n_i &&  cas_n_i && !we_n_i)         cmd_name = a10_i ? "PREA" : "PRE";
            else if (!ras_n_i &&  cas_n_i &&  we_n_i)         cmd_name = "ACT";
            else if ( ras_n_i && !cas_n_i && !we_n_i)         cmd_name = a10_i ? "WRA" : "WR";
            else if ( ras_n_i && !cas_n_i &&  we_n_i)         cmd_name = a10_i ? "RDA" : "RD";
            else if ( ras_n_i &&  cas_n_i && !we_n_i)         cmd_name = a10_i ? "ZQCL" : "ZQCS";
            else                                               cmd_name = "NOP";
        end
    endfunction

    always @(posedge clk) if (rst_n) begin
        $display("%8t ch0: %s  ba=%0d addr=%0d  | cke=%b odt=%b rst_n=%b | init=%b sr=%b pdn=%b",
                  $time, cmd_name(cs_n[0], ras_n[0], cas_n[0], we_n[0], addr[10], cke[0]),
                  ba[BA_BITS-1:0], addr[ADDR_BITS-1:0], cke[0], odt[0], reset_n[0],
                  init_done[0], sr_active[0], pdn_active[0]);
    end

    // ---- request helper task ---------------------------------------------
    task do_req;
        input               chan;
        input               we;
        input               close_page;
        input [BA_BITS-1:0] bank;
        input [ROW_BITS-1:0] row;
        input [COL_BITS-1:0] col;
        begin
            @(posedge clk);
            app_addr       = {chan, row, bank, col};
            app_we         = we;
            app_close_page = close_page;
            app_req        = 1'b1;
            @(posedge clk);
            while (!app_ack) @(posedge clk);
            app_req = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("ddr4_mc_tb.vcd");
        $dumpvars(0, ddr4_mc_tb);

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Wait for channel 0 JEDEC init (RESET#/CKE/MRS0-3/ZQCL) to finish.
        wait (init_done[0] == 1'b1);
        $display("---- channel 0 init done at %0t ----", $time);

        // Open-page write then read hit on the same row/bank (WR, then RD).
        do_req(1'b0, 1'b1, 1'b0, 3'd2, 17'd100, 10'd5);   // ACT + WR
        do_req(1'b0, 1'b0, 1'b0, 3'd2, 17'd100, 10'd6);   // RD (row already open)

        // Row-buffer miss: same bank, different row -> PRE, then ACT + RD.
        do_req(1'b0, 1'b0, 1'b0, 3'd2, 17'd200, 10'd1);

        // Close-page accesses -> WRA / RDA (auto-precharge).
        do_req(1'b0, 1'b1, 1'b1, 3'd5, 17'd50, 10'd3);
        do_req(1'b0, 1'b0, 1'b1, 3'd5, 17'd50, 10'd3);

        // Let a periodic REF fire naturally (tREFI=300 cycles in this sim).
        repeat (350) @(posedge clk);

        // Self-refresh entry/exit (SRE/SRX via CKE).
        $display("---- requesting self-refresh on channel 0 ----");
        sre_req[0] = 1'b1;
        repeat (60) @(posedge clk);
        sre_req[0] = 1'b0;
        wait (sr_active[0] == 1'b0);
        $display("---- self-refresh exit complete at %0t ----", $time);

        // Power-down entry/exit (PDE/PDX via CKE).
        $display("---- requesting power-down on channel 0 ----");
        pd_req[0] = 1'b1;
        repeat (20) @(posedge clk);
        pd_req[0] = 1'b0;
        wait (pdn_active[0] == 1'b0);
        $display("---- power-down exit complete at %0t ----", $time);

        repeat (50) @(posedge clk);
        $display("---- testbench complete ----");
        $finish;
    end

    // Safety timeout
    initial begin
        #20000;
        $display("ERROR: testbench timeout");
        $finish;
    end
endmodule
