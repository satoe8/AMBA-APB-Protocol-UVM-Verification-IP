// -----------------------------------------------------------------------------
// apb_if.sv : AMBA APB4 interface
//   - Clocking blocks : drv_cb (master role), slv_cb (slave role), mon_cb (passive)
//   - Modports        : DRV, SLV, MON
//   - SVA             : protocol checkers bound directly to the pins (PRD 4.2)
//   - Cover           : reachability of corner cases (PRD 3.2)
//
// Compile this file BEFORE the testbench top (interfaces cannot live in a
// package). Only ONE of DRV / SLV may drive a given interface instance.
// Output skew is 1ns, so the clock period must be > 1ns.
// -----------------------------------------------------------------------------
`ifndef APB_IF_SV
`define APB_IF_SV

`include "uvm_macros.svh"

// Reports a checker failure through UVM and counts it for end-of-test closure.
`define APB_SVA_FAIL(ID, MSG) \
  begin \
    sva_fail_cnt++; \
    `uvm_error(ID, MSG) \
  end

// Common clock/disable header for checkers that are active only out of reset.
`define APB_CK @(posedge PCLK) disable iff (!PRESETn || !checks_en)

interface apb_if #(parameter int unsigned ADDR_WIDTH = 32,
                   parameter int unsigned DATA_WIDTH = 32)
                  (input logic PCLK,
                   input logic PRESETn);

  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;

  localparam int unsigned STRB_W = DATA_WIDTH / 8;

  // --------------------------------------------------------------------------
  // APB4 signals
  // --------------------------------------------------------------------------
  logic                    PSEL;
  logic                    PENABLE;
  logic                    PWRITE;
  logic [ADDR_WIDTH-1:0]   PADDR;
  logic [DATA_WIDTH-1:0]   PWDATA;
  logic [STRB_W-1:0]       PSTRB;
  logic [2:0]              PPROT;
  logic [DATA_WIDTH-1:0]   PRDATA;
  logic                    PREADY;
  logic                    PSLVERR;

  // --------------------------------------------------------------------------
  // Control / status knobs
  // --------------------------------------------------------------------------
  bit          checks_en    = 1'b1;  // tests may clear this for negative testing
  int unsigned sva_fail_cnt = 0;     // read by the env's check_phase

  // --------------------------------------------------------------------------
  // Derived phase indicators (combinational, for readability)
  // --------------------------------------------------------------------------
  wire apb_setup  = PSEL & ~PENABLE;            // SETUP  phase
  wire apb_access = PSEL &  PENABLE;            // ACCESS phase (any cycle)
  wire apb_done   = PSEL &  PENABLE & PREADY;   // last cycle of a transfer

  // --------------------------------------------------------------------------
  // Clocking blocks
  // --------------------------------------------------------------------------
  // Master role: drives request, samples completer response
  clocking drv_cb @(posedge PCLK);
    default input #1step output #1;
    input  PRESETn;  // sampled with the bus so reset and signals share one time base
    output PSEL, PENABLE, PWRITE, PADDR, PWDATA, PSTRB, PPROT;
    input  PRDATA, PREADY, PSLVERR;
  endclocking : drv_cb

  // Slave (completer) role: samples request, drives response
  clocking slv_cb @(posedge PCLK);
    default input #1step output #1;
    input  PRESETn;  // sampled with the bus so reset and signals share one time base
    input  PSEL, PENABLE, PWRITE, PADDR, PWDATA, PSTRB, PPROT;
    output PRDATA, PREADY, PSLVERR;
  endclocking : slv_cb

  // Passive observation: every signal is an input
  clocking mon_cb @(posedge PCLK);
    default input #1step;
    input PRESETn;   // sampled with the bus so reset and signals share one time base
    input PSEL, PENABLE, PWRITE, PADDR, PWDATA, PSTRB, PPROT,
          PRDATA, PREADY, PSLVERR;
  endclocking : mon_cb

  modport DRV (clocking drv_cb, input PCLK, PRESETn);
  modport SLV (clocking slv_cb, input PCLK, PRESETn);
  modport MON (clocking mon_cb, input PCLK, PRESETn);

  // ==========================================================================
  // SVA: protocol compliance (PRD 4.2). Active only out of reset.
  // ==========================================================================

  // --- PRD SVA #1 (non-vacuous forms) ----------------------------------------
  // First cycle of a select is a SETUP cycle: PENABLE must be low.
  property p_setup_penable_low;
    `APB_CK $rose(PSEL) |-> !PENABLE;
  endproperty
  a_setup_penable_low: assert property (p_setup_penable_low)
    else `APB_SVA_FAIL("APB_SVA_SETUP", "PENABLE high in first cycle of PSEL (SETUP phase)")

  // PENABLE is meaningless without PSEL.
  property p_penable_needs_psel;
    `APB_CK PENABLE |-> PSEL;
  endproperty
  a_penable_needs_psel: assert property (p_penable_needs_psel)
    else `APB_SVA_FAIL("APB_SVA_PENSEL", "PENABLE asserted without PSEL")

  // SETUP lasts exactly one cycle and always advances to ACCESS.
  property p_setup_to_access;
    `APB_CK apb_setup |=> (PSEL && PENABLE);
  endproperty
  a_setup_to_access: assert property (p_setup_to_access)
    else `APB_SVA_FAIL("APB_SVA_S2A", "SETUP did not advance to ACCESS on next cycle")

  // Request signals must not change between SETUP and ACCESS.
  property p_setup_to_access_stable;
    `APB_CK apb_setup |=> ($stable(PADDR) && $stable(PWRITE) && $stable(PPROT) &&
                           $stable(PSTRB) && (!PWRITE || $stable(PWDATA)));
  endproperty
  a_setup_to_access_stable: assert property (p_setup_to_access_stable)
    else `APB_SVA_FAIL("APB_SVA_S2A_STB", "Request signals changed between SETUP and ACCESS")

  // --- PRD SVA #2: stability while PREADY is low -----------------------------
  property p_access_stable_until_ready;
    `APB_CK (apb_access && !PREADY) |=>
            ($stable(PSEL) && $stable(PENABLE) && $stable(PADDR) &&
             $stable(PWRITE) && $stable(PPROT) && $stable(PSTRB) &&
             (!PWRITE || $stable(PWDATA)));
  endproperty
  a_access_stable_until_ready: assert property (p_access_stable_until_ready)
    else `APB_SVA_FAIL("APB_SVA_STABLE", "Address/control changed while PREADY low in ACCESS")

  // --- PRD SVA #3: PENABLE drops one cycle after the completing ACCESS cycle -
  property p_end_of_transfer;
    `APB_CK apb_done |=> !PENABLE;
  endproperty
  a_end_of_transfer: assert property (p_end_of_transfer)
    else `APB_SVA_FAIL("APB_SVA_EOT", "PENABLE not deasserted one cycle after transfer completion")

  // --- Additional APB4 rules --------------------------------------------------
  // PSTRB must not be active during a read.
  property p_read_strb_zero;
    `APB_CK (PSEL && !PWRITE) |-> (PSTRB == '0);
  endproperty
  a_read_strb_zero: assert property (p_read_strb_zero)
    else `APB_SVA_FAIL("APB_SVA_RDSTRB", "PSTRB non-zero during read transfer")

  // Master drives an idle bus during reset.
  property p_reset_idle;
    @(posedge PCLK) disable iff (!checks_en)
    ($past(!PRESETn) && !PRESETn) |-> (!PSEL && !PENABLE);
  endproperty
  a_reset_idle: assert property (p_reset_idle)
    else `APB_SVA_FAIL("APB_SVA_RST", "PSEL/PENABLE not low during reset")

  // --- X/Z checks on the signals that are valid in each phase ----------------
  property p_no_x_ctrl;
    `APB_CK !$isunknown({PSEL, PENABLE});
  endproperty
  a_no_x_ctrl: assert property (p_no_x_ctrl)
    else `APB_SVA_FAIL("APB_SVA_X_CTRL", "PSEL/PENABLE unknown")

  property p_no_x_request;
    `APB_CK PSEL |-> (!$isunknown({PADDR, PWRITE, PPROT, PSTRB}) &&
                      (!PWRITE || !$isunknown(PWDATA)));
  endproperty
  a_no_x_request: assert property (p_no_x_request)
    else `APB_SVA_FAIL("APB_SVA_X_REQ", "Request signals unknown while PSEL high")

  property p_no_x_ready;
    `APB_CK apb_access |-> !$isunknown(PREADY);
  endproperty
  a_no_x_ready: assert property (p_no_x_ready)
    else `APB_SVA_FAIL("APB_SVA_X_RDY", "PREADY unknown during ACCESS")

  // PSLVERR is only qualified in the last cycle; PRDATA only on an OK read.
  property p_no_x_response;
    `APB_CK apb_done |-> (!$isunknown(PSLVERR) &&
                          (PWRITE || PSLVERR || !$isunknown(PRDATA)));
  endproperty
  a_no_x_response: assert property (p_no_x_response)
    else `APB_SVA_FAIL("APB_SVA_X_RSP", "PSLVERR/PRDATA unknown at transfer completion")

  // ==========================================================================
  // Cover: prove the corner cases in PRD 3.2 / 4.1 are actually reachable
  // ==========================================================================
  c_zero_wait_xfer:   cover property (`APB_CK apb_setup ##1 apb_done);
  c_wait_state_xfer:  cover property (`APB_CK apb_setup ##1 (apb_access && !PREADY) ##1 apb_done);
  c_back_to_back:     cover property (`APB_CK apb_done ##1 apb_setup);
  c_idle_gap:         cover property (`APB_CK apb_done ##1 !PSEL);
  c_wr_to_rd:         cover property (`APB_CK ((apb_done && PWRITE)  ##1 (apb_setup && !PWRITE)));
  c_rd_to_wr:         cover property (`APB_CK ((apb_done && !PWRITE) ##1 (apb_setup &&  PWRITE)));
  c_error_response:   cover property (`APB_CK apb_done && PSLVERR);

endinterface : apb_if

`undef APB_CK
`undef APB_SVA_FAIL

`endif // APB_IF_SV