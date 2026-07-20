//---------------------------------------------------------------------------
// ddr4_refresh_ctrl
//
// Generates REF requests every tREFI controller-clock cycles and tracks
// the tRFC busy window that follows an issued REF. JEDEC JESD79-4 allows
// deferring up to 8 refreshes before one becomes mandatory; `pending`
// models that credit counter so short bursts of traffic don't get
// interrupted by every single tREFI tick, while `ref_urgent` forces
// the channel controller to service refresh ahead of any read/write once
// the credit is exhausted.
//---------------------------------------------------------------------------
module ddr4_refresh_ctrl #(
    parameter tREFI = 1560,   // avg refresh interval, in controller clocks
    parameter tRFC  = 420     // refresh cycle time,  in controller clocks
)(
    input  wire clk,
    input  wire rst_n,

    input  wire ref_issued,   // pulse: a REF command was issued this cycle
    output reg  ref_req,      // level: at least one refresh is due
    output reg  ref_urgent,   // level: refresh credit exhausted, must service now
    output reg  rfc_busy      // level: tRFC busy window following a REF
);
    reg [15:0] refi_cnt;
    reg [15:0] rfc_cnt;
    reg [3:0]  pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refi_cnt   <= 16'd0;
            rfc_cnt    <= 16'd0;
            pending    <= 4'd0;
            ref_req    <= 1'b0;
            ref_urgent <= 1'b0;
            rfc_busy   <= 1'b0;
        end else begin
            if (refi_cnt == tREFI[15:0] - 16'd1) begin
                refi_cnt <= 16'd0;
                if (pending < 4'd8) pending <= pending + 4'd1;
            end else begin
                refi_cnt <= refi_cnt + 16'd1;
            end

            if (ref_issued) begin
                rfc_cnt  <= tRFC[15:0] - 16'd1;
                rfc_busy <= 1'b1;
                if (pending != 4'd0) pending <= pending - 4'd1;
            end else if (rfc_busy) begin
                if (rfc_cnt == 16'd0) rfc_busy <= 1'b0;
                else                  rfc_cnt  <= rfc_cnt - 16'd1;
            end

            ref_req    <= (pending != 4'd0);
            ref_urgent <= (pending >= 4'd8);
        end
    end
endmodule
