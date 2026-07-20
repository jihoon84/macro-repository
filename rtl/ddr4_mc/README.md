# ddr4_mc — 2-Channel / 8-Bank DDR4 Memory Controller (Verilog)

Verilog-2001 reference DDR4 memory controller: 2 independent channels, 8
banks per channel, and the full DDR4 command set (MRS, REF, SRE/SRX,
PRE/PREA, ACT, RD/RDA, WR/WRA, ZQCL/ZQCS, PDE/PDX, NOP, DES).

## Scope

This is a command/timing engine, not a full memory subsystem:

- **In scope**: JEDEC init sequence, per-bank timing (tRCD/tRAS/tRP/tWR/
  tRTP), channel-wide spacing (tRRD/tFAW/tCCD/tWTR), refresh scheduling
  with JEDEC's 8x deferral credit and tRFC enforcement, self-refresh
  entry/exit, power-down entry/exit, periodic ZQCS, open-page (row-buffer
  hit/miss) and close-page (auto-precharge) access.
- **Out of scope**: the DQ/DQS data path, write-leveling, read/write
  calibration, and ODT sequencing detail — all PHY (DFI or vendor hard IP)
  responsibilities. The controller only drives the command/address/control
  bus (`cs_n/ras_n/cas_n/we_n/addr/ba/cke/odt/reset_n`) plus a CL-aligned
  `app_rvalid` strobe that a PHY would pair with the real DQ bus.
- Front-end is a minimal single-outstanding request/ack interface, enough
  to exercise every command legally and in the right order. A production
  controller would replace it with a multi-entry, reorderable command
  queue — the bank/refresh/timing engine underneath does not need to
  change to support that.

## Files

| File | Purpose |
|---|---|
| `ddr4_defines.vh` | Internal command opcodes, bank/channel FSM states |
| `ddr4_cmd_encoder.v` | Opcode -> CS_n/RAS_n/CAS_n/WE_n/A10 pin-level truth table |
| `ddr4_bank_fsm.v` | Per-bank IDLE/ACTIVE/PRECHARGING timing (tRCD/tRAS/tRP/tWR/tRTP), explicit and auto-precharge |
| `ddr4_refresh_ctrl.v` | tREFI/tRFC refresh scheduler, 8x deferral credit |
| `ddr4_channel.v` | One channel: init sequence, 8x bank FSM, tRRD/tFAW/tCCD/tWTR, command dispatch, self-refresh/power-down |
| `ddr4_mc_top.v` | 2-channel top; splits a flat address into `{channel, row, bank, column}` |
| `tb/ddr4_mc_tb.v` | Smoke test exercising every command; decodes and traces channel 0's command bus |

## Address map (`ddr4_mc_top`)

`app_addr = { chan[1 bit] | row[ROW_BITS] | bank[BA_BITS] | col[COL_BITS] }`

Defaults: `ROW_BITS=17, BA_BITS=3 (8 banks), COL_BITS=10` -> 31-bit `app_addr`.

## Timing parameters

All DRAM timing is expressed in **controller clock cycles** and passed as
module parameters (`tRCD, tRAS, tRP, tWR, tRTP, tRRD, tFAW, tCCD, tWTR,
tREFI, tRFC, tXS, CL`). The defaults are placeholders in the ballpark of a
DDR4-2400 speed bin — **program the actual values from your target DDR4
device's datasheet / JESD79-4 speed-bin table** before using this for
anything beyond simulation. Likewise `MR0_VAL..MR3_VAL` (mode register
payloads) default to 0 and must be programmed per JESD79-4 §3.5 for the
chosen speed bin and burst/latency configuration.

`RESET_CYCLES/CKE_CYCLES/MRD_CYCLES/ZQINIT_CYCLES` model the JEDEC init
sequence's real-world delays (tPW_RESET_L ~200us, tXPR, tMRD, tZQinit);
they are deliberately shrunk in the testbench for fast simulation and
must be widened to datasheet values for real silicon.

## Simulating

```sh
cd rtl/ddr4_mc
iverilog -g2001 -o /tmp/ddr4_mc_tb.vvp -I . \
  ddr4_cmd_encoder.v ddr4_bank_fsm.v ddr4_refresh_ctrl.v \
  ddr4_channel.v ddr4_mc_top.v tb/ddr4_mc_tb.v
vvp /tmp/ddr4_mc_tb.vvp
```

Produces `ddr4_mc_tb.vcd` (viewable with GTKWave) and a per-cycle console
trace of channel 0's decoded command bus. The testbench walks through:
init -> open-page write+read hit -> row-buffer-miss (PRE+ACT) ->
close-page write+read (WRA/RDA) -> a naturally-scheduled REF -> forced
self-refresh entry/exit -> forced power-down entry/exit.

## Known simplifications

- tCCD/tWTR use a single (conservative) value rather than distinguishing
  same-bank-group vs. different-bank-group timing (tCCD_S vs tCCD_L).
- The front-end holds one outstanding request; there is no reordering,
  bank-parallel pipelining of independent requests, or write-data
  buffering.
- MPC (multi-purpose command, e.g. VREF training) is not implemented.
