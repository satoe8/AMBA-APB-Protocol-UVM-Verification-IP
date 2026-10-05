# AMBA APB UVM Verification IP (slave-responder, self-checking)

A reusable, parameterized UVM 1.2 Verification IP for the AMBA APB (APB4) protocol, written in
SystemVerilog and built for an APB bridge core. The VIP acts as the **APB slave / completer**:
it injects wait states by holding `PREADY` low, answers with a built-in register-file model, and
flags errors with `PSLVERR`. A **master-role agent** is included so the whole VIP can be verified
end-to-end without any DUT.

## Status

| Item | State |
|---|---|
| Smoke test on Questa | **Passed** (0 `UVM_ERROR`, 0 `UVM_FATAL`, `APB SCOREBOARD: PASS`) |
| Static check of the full VIP (slang + Accellera `uvm-core`) | 0 errors, 0 warnings in VIP files |
| Full regression and merged coverage | Run it with the commands below and record the numbers in `PORTFOLIO.md` |

No coverage percentage is claimed in this repository until you have generated it from your own run.

## Features

- Parameterized address and data width (`ADDR_WIDTH`, `DATA_WIDTH`, default 32/32).
- Constrained-random sequence item: address classes (valid, protected, unmapped, boundary),
  data patterns (walking 1/0, alternating `AA`/`55`, min/max, random), wait states, idle gaps.
- Slave responder with per-transfer wait-state injection (0 to 16 cycles) and junk on `PRDATA`
  while `PREADY` is low, to catch bridges that sample read data early.
- Register-file model: unmapped access and writes to the protected window return `PSLVERR`;
  sparse writes honor `PSTRB` byte lanes; backdoor `peek()`/`poke()`.
- Scoreboard with an independent shadow memory, error prediction, driver-vs-monitor comparison,
  and an `uvm_analysis_imp` hook for an upstream predictor.
- 12 concurrent assertions and 7 cover properties inside the interface.
- Functional coverage: transaction, error, sequence (turnaround/idle), data pattern, and
  bus-observed FSM.
- Master-role agent and sequence library for self-contained verification.
- Questa Makefile with seeded regression, UCDB merge, and text/HTML coverage reports.

## Architecture

```
                         +------------------------ apb_env ---------------------------+
                         |                                                            |
   test (apb_*_test) --> |  mst_agt                          slv_agt                  |
   starts sequences      |  +-------------+                  +----------------------+|
                         |  | sequencer   |                  | sequencer (plans)    ||
                         |  | master drv  |                  | slave drv + mem model||
                         |  +------+------+                  | monitor              ||
                         |         | ap (driven items)       +---+------+------+----+|
                         |         |                       ap |      |resp_ap|      |
                         |         v exp_imp                  v      v       |      |
                         |      +--------------- scoreboard ---------+       |      |
                         |      | C1 PSLVERR  C2 write integrity     |<------+      |
                         |      | C3 read data C4 mon-vs-drv  C5 upstream           |
                         |      +------------------------------------+              |
                         |      coverage collector  <---- ap ------------------------+
                         +------------------------------------------------------------+
                                  |                    ^
                                  v   apb_if (clocking blocks, SVA, covers)
                         master signals  ------------>  slave signals (PREADY/PRDATA/PSLVERR)
```

Both agents attach to the same `apb_if`. The master drives the request signals through
`drv_cb`, the slave drives the response signals through `slv_cb`, and the monitor, SVA and
coverage only observe through `mon_cb`. A second monitor is deliberately not built.

## Files

| File | Role |
|---|---|
| `apb_if.sv` | Interface: `drv_cb` / `slv_cb` / `mon_cb`, modports, 12 SVA checks, 7 cover properties, `sva_fail_cnt` |
| `apb_pkg.sv` | Package: shared enums, includes all classes in dependency order |
| `apb_seq_item.sv` | Parameterized sequence item, constraints, `do_copy` / `do_compare` / `convert2string` |
| `apb_monitor.sv` | Passive monitor; one item per completed transfer, with wait count and idle gap |
| `apb_mem_model.sv` | Register-file model and address-map error rules (the shared golden handle) |
| `apb_slave_driver.sv` | Slave responder; plan queue, wait-state injection, memory commit |
| `apb_master_driver.sv` | Master driver; SETUP/ACCESS, back-to-back, idle gaps, timeout, reset abort |
| `apb_agent_config.sv` | Configuration object (vif, address map, knobs) |
| `apb_slave_sequencer.sv`, `apb_agent.sv` | Slave-role sequencer and agent (active or passive) |
| `apb_master_agent.sv` | Master-role agent (sequencer + master driver) |
| `apb_slave_seq_lib.sv` | Wait-state sequences: zero, fixed, random, ramp, alternating, regression |
| `apb_master_seq_lib.sv` | Stimulus: random, write/read-back, walking data, address classes, boundary, burst sweep, turnaround, regression |
| `apb_scoreboard.sv` | Bus-level checks and upstream predictor hook |
| `apb_coverage.sv` | Covergroups and bus-observed FSM sampling |
| `apb_env.sv` | Env config and env (wiring of everything above) |
| `apb_tests.sv` | Package `apb_test_pkg`: smoke, regression, random, reset tests |
| `tb_top.sv` | Clock, reset (with optional mid-run reset), interface, `run_test()` |
| `Makefile`, `check_log.sh` | Questa flow and pass/fail from the UVM report summary |

Top-level compile order is `apb_if.sv`, `apb_pkg.sv`, `apb_tests.sv`, `tb_top.sv`
(everything else is included by `apb_pkg.sv`).

## Key design decisions

1. **Slave role.** PRD §3.2 requires holding `PREADY` low, which is slave behavior. PRD §2
   describes a SETUP/ACCESS driver, which is master behavior. Both are implemented; one role is
   active per interface instance in a real DUT setup, and both together form the self-test.
2. **Slave timing.** The slave decides `PREADY` one cycle ahead: it samples SETUP at edge N and
   drives `PREADY` for the ACCESS cycle. With `wait_states = 0` the transfer takes two cycles.
3. **Race-free write commit.** A write commits to the memory when `PREADY=1` is presented, one
   cycle before the monitor publishes the transfer. The scoreboard can therefore read the memory
   when the monitor item arrives.
4. **Independent checking.** The scoreboard builds its own shadow memory from monitored writes
   and re-implements the address-map rules, so a bug in the driver's model cannot hide in the checker.
5. **Reset.** Every component handles reset: transfers in flight are aborted and counted, the
   shadow and driver memories are cleared (configurable), and coverage never forms a sequence
   across reset. `tb_top` changes reset on the falling edge to avoid sampling races.
6. **Pass/fail from the log.** Questa can exit 0 on a UVM error, so `check_log.sh` decides.

## Tests

| Test | Purpose |
|---|---|
| `apb_smoke_test` | Short write/read-back sanity run |
| `apb_regression_test` | Directed + random closure run; **enforces the coverage goal** (default 100%) |
| `apb_random_test` | Constrained-random traffic, random wait states; `+NUM_ITEMS=<n>`; vary the seed |
| `apb_reset_test` | Random traffic with a reset pulse: `+MID_RESET_AT=<cycle> +MID_RESET_LEN=<cycles>` |

## Protocol checks (SVA in `apb_if.sv`)

| Assertion | Rule |
|---|---|
| `a_setup_penable_low` | `PENABLE` is low in the first cycle of a `PSEL` assertion (SETUP) |
| `a_penable_needs_psel` | `PENABLE` never asserts without `PSEL` |
| `a_setup_to_access` | SETUP lasts exactly one cycle and always advances to ACCESS |
| `a_setup_to_access_stable` | Request signals do not change between SETUP and ACCESS |
| `a_access_stable_until_ready` | `PSEL`, `PENABLE`, address, control, `PSTRB`, `PPROT` (and `PWDATA` on writes) stay stable while `PREADY` is low |
| `a_end_of_transfer` | `PENABLE` deasserts one cycle after the completing ACCESS cycle (`PSEL && PENABLE && PREADY`) |
| `a_read_strb_zero` | `PSTRB` is zero during a read |
| `a_reset_idle` | `PSEL` and `PENABLE` are low during reset |
| `a_no_x_ctrl`, `a_no_x_request`, `a_no_x_ready`, `a_no_x_response` | No X/Z on the signals that are valid in each phase |

Cover properties: `c_zero_wait_xfer`, `c_wait_state_xfer`, `c_back_to_back`, `c_idle_gap`,
`c_wr_to_rd`, `c_rd_to_wr`, `c_error_response`. Failures are reported through `uvm_error`, counted
in `sva_fail_cnt`, and rolled into the scoreboard's `check_phase`.

## Scoreboard checks

| Check | Description |
|---|---|
| C1 | `PSLVERR` equals an independently predicted error (unmapped; write to protected) |
| C2 | The driver's memory equals the scoreboard shadow after every write (an errored write must not commit) |
| C3 | `PRDATA` of an error-free read equals the shadow value built from observed bus writes |
| C4 | Each monitored item equals the slave driver's item (`compare()`), including the wait-state count |
| C5 | Upstream compare against an expected item (master agent in self-test, your predictor with a DUT) |

`check_phase` also fails on SVA failures, unmatched queue leftovers, and warns on a run that saw zero transfers.

## Functional coverage (`apb_coverage.sv`)

| Covergroup | Content |
|---|---|
| `cg_txn` | Direction x address bucket (8, including region-edge buckets) x wait group; 17 individual wait values; back-to-back run length (1, 2, 3-4, 5-8, 9+); 3 crosses plus a triple cross |
| `cg_err` | `PSLVERR` x direction x address class: 6 legal bins, 3 `illegal_bins` (missing error response), 3 ignored |
| `cg_seq` | Previous-direction x direction turnaround x idle gap (0, 1, 2, 3+): 16 bins |
| `cg_data` | 7 data classes x direction, plus walking-1 and walking-0 bit positions |
| `cg_fsm` | Bus-observed IDLE / SETUP / ACCESS_WAIT / ACCESS_DONE: full 4x4 transition cross with 8 legal and 8 illegal bins, plus state x direction |

"Burst length" is defined as the length of a run of back-to-back transfers (`idle_cycles == 0`),
because APB itself has no bursts. The FSM coverage is derived from bus signals, not from the DUT's
internal state register; `sample_dut_fsm()` is the extension point for RTL FSM coverage.

### Closure strategy

Random stimulus alone cannot reliably hit crosses such as (boundary address) x (direction) x
(wait group). The regression therefore runs the slave's ramp (wait states 0, 1, ..., 16, repeating) in
the background and repeats each master address sequence 17 times. The address sequence sends 6
items per repetition and the boundary sequence sends 10, both coprime with 17, so every
(address, direction) item meets every wait value regardless of the starting offset.

## Running (Questa)

```
make run TEST=apb_smoke_test SEED=1          # one test, one seed
make regress SEEDS="1 2 3"                   # all tests x seeds, then merge + text report
make html                                    # HTML coverage report
make run TEST=apb_reset_test EXTRA_PLUSARGS="+MID_RESET_AT=300 +MID_RESET_LEN=4"
make gui TEST=apb_regression_test            # waveforms
make clean
```

Outputs: `out/log/<test>_<seed>.log`, `out/cov/<test>_<seed>.ucdb`, `out/cov/merged.ucdb`,
`out/cov/merged_report.txt`, `out/cov/html/index.html`. Set `CODECOV=1` to add code coverage.
Set `UVM_HOME` only if your install needs an explicit UVM include path.

## Using this VIP with your bridge

1. Instantiate `apb_if` and connect it to the DUT's APB port.
2. Set `has_master = 0` in `apb_env_config` (the DUT is the master).
3. Connect your upstream predictor's output to `sb.exp_imp` and set `sb.enable_upstream_check = 1`.
4. Drive upstream traffic that exercises addresses, boundaries and data patterns. The slave side
   alone can close wait-state, `PSLVERR` and read-data bins, but the DUT drives addresses and write data.
5. Preload read-only registers with `sb.preload(addr, data)`, not `mem.poke()`.
6. Set the address map in `apb_agent_config` (`map_lo/hi`, `ro_lo/hi`).

## PRD interpretation notes

- PRD "burst lengths" are modeled as back-to-back run lengths (see above).
- PRD SVA #1 ("`PENABLE` deasserted during SETUP") is true by definition of SETUP, so it is
  implemented as three non-vacuous checks: `PENABLE` low on the first `PSEL` cycle, no `PENABLE`
  without `PSEL`, and SETUP always advancing to ACCESS.
- PRD SVA #3 is anchored on the completing ACCESS cycle, so it also holds in back-to-back traffic.
- PRD "bidirectional data paths": APB has separate `PWDATA` and `PRDATA`, so contention can only
  occur on the handshake signals; the master and slave clocking blocks drive disjoint signals.

## Known limitations

- Not yet run on a real bridge DUT; no upstream (AXI/AHB) agent is included.
- Bus-observed FSM coverage verifies APB-side behavior, not the DUT's internal states.
- Only one role (master or slave) may drive a given interface instance.
- The address map is stored in static members of `apb_seq_item`, so it is shared by all agents
  of the same width specialization.
- Closure numbers depend on the simulator run; none are asserted here.
