`ifndef DDR4_DEFINES_VH
`define DDR4_DEFINES_VH
//---------------------------------------------------------------------------
// Internal DDR4 command opcodes.
//
// These are translated to the pin-level CS_n/RAS_n/CAS_n/WE_n/A10 truth
// table by ddr4_cmd_encoder. On a real JEDEC DDR4 device RAS_n/CAS_n/WE_n
// are physically multiplexed onto A16/A15/A14 (only ACT drives a real row
// address on those pins); this controller keeps them as separate signals
// on its internal command bus for readability, exactly as most DDR
// controller front-ends do, and a PHY/DFI adaptation layer would perform
// the final pin muxing.
//---------------------------------------------------------------------------
`define CMD_MRS   4'h0   // Mode Register Set
`define CMD_REF   4'h1   // Refresh
`define CMD_SRE   4'h2   // Self-Refresh Entry   (REF encoding + CKE falling)
`define CMD_SRX   4'h3   // Self-Refresh Exit    (DES/NOP encoding + CKE rising)
`define CMD_PRE   4'h4   // Precharge (single bank, A10=0)
`define CMD_PREA  4'h5   // Precharge All        (A10=1)
`define CMD_ACT   4'h6   // Activate
`define CMD_WR    4'h7   // Write
`define CMD_WRA   4'h8   // Write with Auto-Precharge (A10=1)
`define CMD_RD    4'h9   // Read
`define CMD_RDA   4'hA   // Read with Auto-Precharge  (A10=1)
`define CMD_NOP   4'hB   // No Operation
`define CMD_DES   4'hC   // Deselect
`define CMD_ZQCL  4'hD   // ZQ Calibration Long  (A10=1, at init)
`define CMD_ZQCS  4'hE   // ZQ Calibration Short (A10=0, periodic)
`define CMD_PDE   4'hF   // Power-Down Entry     (DES encoding + CKE falling)
// Power-down exit (PDX) is a plain CKE 0->1 transition applied alongside
// DES/NOP, so it reuses CMD_DES/CMD_NOP with the `cke` output raised.

// Bank state-machine states
`define BANK_IDLE         3'd0
`define BANK_ACTIVE       3'd1
`define BANK_PRECHARGING  3'd2

// Channel-level control FSM states
`define CH_S_RESET        4'd0
`define CH_S_INIT_CKE     4'd1
`define CH_S_INIT_MRS     4'd2
`define CH_S_INIT_ZQCL    4'd3
`define CH_S_INIT_WAIT    4'd4
`define CH_S_CTRL         4'd5   // steady-state command dispatch
`define CH_S_SELFREF      4'd6
`define CH_S_PWRDN        4'd7

`endif
