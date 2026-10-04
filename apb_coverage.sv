// -----------------------------------------------------------------------------
// apb_coverage.sv : functional coverage collector (included inside apb_pkg)
//
// Subscribes to agent.ap (monitor items) and, for FSM coverage, samples the bus
// phase every clock through vif.mon_cb.
//
//   cg_txn  : direction x address bucket x wait-state group x back-to-back run
//   cg_err  : PSLVERR x direction x address class (PRD 4.1 error coverage)
//   cg_seq  : read/write turnaround x idle gap     (PRD 3.2)
//   cg_data : data class x direction, walking-1/0 bit positions (PRD 3.1)
//   cg_fsm  : bus-observed IDLE/SETUP/ACCESS_WAIT/ACCESS_DONE + transitions
//
// "Burst length" = length of a run of back-to-back transfers (idle_cycles == 0);
// APB itself has no bursts.
//
// illegal_bins raise a simulator error when hit: they mirror protocol and
// scoreboard rules and are expected to stay at zero.
//
// Hookup: agent.ap.connect(cov.analysis_export);  optional config_db "vif".
// -----------------------------------------------------------------------------

// Bus-observed phase of one clock cycle
typedef enum {
  BUS_IDLE,         // PSEL low
  BUS_SETUP,        // PSEL high, PENABLE low
  BUS_ACCESS_WAIT,  // PSEL, PENABLE high, PREADY low
  BUS_ACCESS_DONE   // PSEL, PENABLE, PREADY high (last cycle of a transfer)
} apb_bus_state_e;

// Address buckets (boundaries are word-granular)
typedef enum {
  AB_MAP_LO,          // first word of the mapped window
  AB_MAP_HI,          // last word of the mapped window
  AB_RO_LO,           // first word of the protected window
  AB_JUST_BELOW_RO,   // last word below the protected window
  AB_JUST_ABOVE_MAP,  // first word above the mapped window (unmapped)
  AB_VALID,           // mapped, writable, not at a boundary
  AB_PROTECTED,       // protected window, not at a boundary
  AB_UNMAPPED         // unmapped, not adjacent to the window
} apb_addr_bucket_e;

// Data classes
typedef enum {
  DC_ZERO, DC_ONES, DC_WALK1, DC_WALK0, DC_ALT_AA, DC_ALT_55, DC_OTHER
} apb_data_class_e;

class apb_coverage #(int unsigned ADDR_WIDTH = 32,
                     int unsigned DATA_WIDTH = 32)
  extends uvm_subscriber #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH)   item_t;
  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef bit [ADDR_WIDTH-1:0]                     addr_t;
  typedef bit [DATA_WIDTH-1:0]                     data_t;

  localparam int unsigned STRB_W   = DATA_WIDTH / 8;
  localparam int unsigned MAX_WAIT = item_t::MAX_WAIT;   // must be >= 9 for the wait groups

  `uvm_component_param_utils(apb_coverage #(ADDR_WIDTH, DATA_WIDTH))

  // --------------------------------------------------------------------------
  // Knobs
  // --------------------------------------------------------------------------
  bit  enable          = 1'b1;
  bit  enable_fsm_cov  = 1'b1;     // needs vif
  real coverage_goal   = 100.0;
  bit  enforce_goal    = 1'b0;     // when 1, check_phase errors if total < goal

  protected vif_t vif;

  // Sequence-tracking state
  protected bit          have_prev_item = 1'b0;
  protected bit          prev_wr        = 1'b0;
  protected int unsigned run_len        = 0;
  int unsigned           num_items      = 0;

  // ==========================================================================
  // Covergroups
  // ==========================================================================

  // ---- Transaction coverage -------------------------------------------------
  covergroup cg_txn with function sample(bit wr, apb_addr_bucket_e ab,
                                         int unsigned wt, int unsigned run);
    option.per_instance = 1;

    cp_dir  : coverpoint wr { bins rd = {0}; bins wrt = {1}; }
    cp_addr : coverpoint ab;
    cp_wait : coverpoint wt {
      bins w[]         = {[0:MAX_WAIT]};
      illegal_bins over = {[MAX_WAIT+1:$]};
    }
    cp_wait_grp : coverpoint wt {
      bins none    = {0};
      bins short_w = {[1:3]};
      bins mid     = {[4:8]};
      bins long_w  = {[9:MAX_WAIT]};
    }
    cp_burst : coverpoint run {
      bins r1    = {1};
      bins r2    = {2};
      bins r3_4  = {[3:4]};
      bins r5_8  = {[5:8]};
      bins r9_up = {[9:$]};
    }

    x_dir_addr      : cross cp_dir, cp_addr;
    x_dir_wait      : cross cp_dir, cp_wait_grp;
    x_dir_burst     : cross cp_dir, cp_burst;
    x_dir_addr_wait : cross cp_dir, cp_addr, cp_wait_grp;
  endgroup

  // ---- Error coverage -------------------------------------------------------
  covergroup cg_err with function sample(bit wr, apb_addr_kind_e cls, bit err);
    option.per_instance = 1;

    cp_dir   : coverpoint wr { bins rd = {0}; bins wrt = {1}; }
    cp_class : coverpoint cls {
      bins valid_c    = {ADDR_VALID};
      bins prot_c     = {ADDR_PROTECTED};
      bins unmapped_c = {ADDR_UNMAPPED};
      ignore_bins bnd = {ADDR_BOUNDARY};   // monitor never produces it
    }
    cp_err : coverpoint err { bins ok = {0}; bins err_resp = {1}; }

    x_err : cross cp_err, cp_dir, cp_class {
      // expected behavior
      bins ok_valid_rd     = binsof(cp_err.ok)       && binsof(cp_dir.rd)  && binsof(cp_class.valid_c);
      bins ok_valid_wr     = binsof(cp_err.ok)       && binsof(cp_dir.wrt) && binsof(cp_class.valid_c);
      bins ok_prot_rd      = binsof(cp_err.ok)       && binsof(cp_dir.rd)  && binsof(cp_class.prot_c);
      bins err_prot_wr     = binsof(cp_err.err_resp) && binsof(cp_dir.wrt) && binsof(cp_class.prot_c);
      bins err_unmapped_rd = binsof(cp_err.err_resp) && binsof(cp_dir.rd)  && binsof(cp_class.unmapped_c);
      bins err_unmapped_wr = binsof(cp_err.err_resp) && binsof(cp_dir.wrt) && binsof(cp_class.unmapped_c);
      // missing error response: always a bug
      illegal_bins bad_prot_wr_ok     = binsof(cp_err.ok) && binsof(cp_dir.wrt) && binsof(cp_class.prot_c);
      illegal_bins bad_unmapped_rd_ok = binsof(cp_err.ok) && binsof(cp_dir.rd)  && binsof(cp_class.unmapped_c);
      illegal_bins bad_unmapped_wr_ok = binsof(cp_err.ok) && binsof(cp_dir.wrt) && binsof(cp_class.unmapped_c);
      // unexpected error: left to the scoreboard (misalignment knob can cause these legitimately)
      ignore_bins unexp_err_valid_rd = binsof(cp_err.err_resp) && binsof(cp_dir.rd)  && binsof(cp_class.valid_c);
      ignore_bins unexp_err_valid_wr = binsof(cp_err.err_resp) && binsof(cp_dir.wrt) && binsof(cp_class.valid_c);
      ignore_bins unexp_err_prot_rd  = binsof(cp_err.err_resp) && binsof(cp_dir.rd)  && binsof(cp_class.prot_c);
    }
  endgroup

  // ---- Sequence-level coverage: turnaround and idle gap ---------------------
  covergroup cg_seq with function sample(bit prev_wr_s, bit wr, int unsigned idle);
    option.per_instance = 1;

    cp_turn : coverpoint {prev_wr_s, wr} {
      bins rd_rd = {2'b00};
      bins rd_wr = {2'b01};
      bins wr_rd = {2'b10};
      bins wr_wr = {2'b11};
    }
    cp_idle : coverpoint idle {
      bins b2b     = {0};
      bins gap1    = {1};
      bins gap2    = {2};
      bins gap3_up = {[3:$]};
    }
    x_turn_idle : cross cp_turn, cp_idle;
  endgroup

  // ---- Data-pattern coverage ------------------------------------------------
  covergroup cg_data with function sample(apb_data_class_e c, bit wr,
                                          int unsigned w1, int unsigned w0);
    option.per_instance = 1;

    cp_class : coverpoint c;
    cp_dir   : coverpoint wr { bins rd = {0}; bins wrt = {1}; }
    cp_w1    : coverpoint w1 iff (c == DC_WALK1) { bins pos[] = {[0:DATA_WIDTH-1]}; }
    cp_w0    : coverpoint w0 iff (c == DC_WALK0) { bins pos[] = {[0:DATA_WIDTH-1]}; }

    x_class_dir : cross cp_class, cp_dir;
  endgroup

  // ---- Bus-observed FSM coverage -------------------------------------------
  covergroup cg_fsm with function sample(apb_bus_state_e st, apb_bus_state_e pv, bit wr);
    option.per_instance = 1;

    cp_st   : coverpoint st;
    cp_prev : coverpoint pv;

    // Full 4x4 previous -> current cross: 8 legal + 8 illegal = 16 bins
    x_trans : cross cp_prev, cp_st {
      bins idle_idle   = binsof(cp_prev) intersect {BUS_IDLE}        && binsof(cp_st) intersect {BUS_IDLE};
      bins idle_setup  = binsof(cp_prev) intersect {BUS_IDLE}        && binsof(cp_st) intersect {BUS_SETUP};
      bins setup_wait  = binsof(cp_prev) intersect {BUS_SETUP}       && binsof(cp_st) intersect {BUS_ACCESS_WAIT};
      bins setup_done  = binsof(cp_prev) intersect {BUS_SETUP}       && binsof(cp_st) intersect {BUS_ACCESS_DONE};
      bins wait_wait   = binsof(cp_prev) intersect {BUS_ACCESS_WAIT} && binsof(cp_st) intersect {BUS_ACCESS_WAIT};
      bins wait_done   = binsof(cp_prev) intersect {BUS_ACCESS_WAIT} && binsof(cp_st) intersect {BUS_ACCESS_DONE};
      bins done_idle   = binsof(cp_prev) intersect {BUS_ACCESS_DONE} && binsof(cp_st) intersect {BUS_IDLE};
      bins done_setup  = binsof(cp_prev) intersect {BUS_ACCESS_DONE} && binsof(cp_st) intersect {BUS_SETUP};  // back-to-back

      illegal_bins bad_from_idle  = binsof(cp_prev) intersect {BUS_IDLE}        && binsof(cp_st) intersect {BUS_ACCESS_WAIT, BUS_ACCESS_DONE};
      illegal_bins bad_from_setup = binsof(cp_prev) intersect {BUS_SETUP}       && binsof(cp_st) intersect {BUS_IDLE, BUS_SETUP};
      illegal_bins bad_from_wait  = binsof(cp_prev) intersect {BUS_ACCESS_WAIT} && binsof(cp_st) intersect {BUS_IDLE, BUS_SETUP};
      illegal_bins bad_from_done  = binsof(cp_prev) intersect {BUS_ACCESS_DONE} && binsof(cp_st) intersect {BUS_ACCESS_WAIT, BUS_ACCESS_DONE};
    }

    // Direction while a transfer is active (SETUP/ACCESS)
    cp_dir : coverpoint wr iff (st != BUS_IDLE) { bins rd = {0}; bins wrt = {1}; }
    x_state_dir : cross cp_st, cp_dir {
      ignore_bins idle_st = binsof(cp_st) intersect {BUS_IDLE};
    }
  endgroup

  // --------------------------------------------------------------------------
  function new(string name = "apb_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_txn  = new();
    cg_err  = new();
    cg_seq  = new();
    cg_data = new();
    cg_fsm  = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
      if (enable_fsm_cov)
        `uvm_warning("APB_COV_NOVIF", "No vif supplied: bus-observed FSM coverage will not be sampled")
  endfunction

  // --------------------------------------------------------------------------
  // Classification helpers
  // --------------------------------------------------------------------------
  protected function addr_t word_key(addr_t a);
    return a & ~addr_t'(STRB_W - 1);
  endfunction

  protected function apb_addr_bucket_e bucket_of(addr_t a);
    addr_t k = word_key(a);
    if (item_t::map_hi != {ADDR_WIDTH{1'b1}} &&
        k == word_key(item_t::map_hi + addr_t'(1)))              return AB_JUST_ABOVE_MAP;
    if (k == word_key(item_t::map_lo))                           return AB_MAP_LO;
    if (k == word_key(item_t::map_hi))                           return AB_MAP_HI;
    if (k == word_key(item_t::ro_lo))                            return AB_RO_LO;
    if (item_t::ro_lo > item_t::map_lo &&
        k == word_key(item_t::ro_lo - addr_t'(1)))               return AB_JUST_BELOW_RO;
    if (a >= item_t::ro_lo  && a <= item_t::ro_hi)               return AB_PROTECTED;
    if (a >= item_t::map_lo && a <= item_t::map_hi)              return AB_VALID;
    return AB_UNMAPPED;
  endfunction

  protected function apb_data_class_e classify_data(data_t d);
    if (d == '0)                          return DC_ZERO;
    if (d == '1)                          return DC_ONES;
    if ($onehot(d))                       return DC_WALK1;
    if ($onehot(~d))                      return DC_WALK0;
    if (d == {(DATA_WIDTH/2){2'b10}})     return DC_ALT_AA;
    if (d == {(DATA_WIDTH/2){2'b01}})     return DC_ALT_55;
    return DC_OTHER;
  endfunction

  // Index of the (single) set bit
  protected function int unsigned bit_pos(data_t d);
    for (int unsigned i = 0; i < DATA_WIDTH; i++)
      if (d[i]) return i;
    return 0;
  endfunction

  protected function void sample_data(data_t d, bit wr);
    apb_data_class_e c;
    int unsigned     w1 = 0;
    int unsigned     w0 = 0;
    c = classify_data(d);
    if      (c == DC_WALK1) w1 = bit_pos(d);
    else if (c == DC_WALK0) w0 = bit_pos(~d);
    cg_data.sample(c, wr, w1, w0);
  endfunction

  protected function apb_bus_state_e decode_bus_state(logic psel, logic penable, logic pready);
    if (psel    !== 1'b1) return BUS_IDLE;
    if (penable !== 1'b1) return BUS_SETUP;
    if (pready  === 1'b1) return BUS_ACCESS_DONE;
    return BUS_ACCESS_WAIT;
  endfunction

  // --------------------------------------------------------------------------
  // Per-transfer sampling (monitor items)
  // --------------------------------------------------------------------------
  virtual function void write(item_t t);
    apb_addr_bucket_e ab;
    num_items++;
    if (!enable) return;

    ab = bucket_of(t.paddr);

    // back-to-back run length ("burst length")
    if (have_prev_item && t.idle_cycles == 0) run_len++;
    else                                      run_len = 1;

    cg_txn.sample(t.pwrite, ab, t.observed_wait_states, run_len);
    cg_err.sample(t.pwrite, t.addr_kind, t.pslverr);
    if (have_prev_item) cg_seq.sample(prev_wr, t.pwrite, t.idle_cycles);

    if (t.pwrite)        sample_data(t.pwdata, 1'b1);
    else if (!t.pslverr) sample_data(t.prdata, 1'b0);   // PRDATA valid only without error

    prev_wr        = t.pwrite;
    have_prev_item = 1'b1;
  endfunction

  // --------------------------------------------------------------------------
  // Per-clock sampling (bus-observed FSM)
  // --------------------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    apb_bus_state_e st, pv;
    bit             have_prev = 1'b0;

    if (vif == null) return;

    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.PRESETn !== 1'b1) begin
        have_prev = 1'b0;                 // never form a transition across reset
        have_prev_item = 1'b0;            // nor a back-to-back run or turnaround
        run_len        = 0;
        continue;
      end
      st = decode_bus_state(vif.mon_cb.PSEL, vif.mon_cb.PENABLE, vif.mon_cb.PREADY);
      if (enable && enable_fsm_cov && have_prev)
        cg_fsm.sample(st, pv, (vif.mon_cb.PWRITE === 1'b1));
      pv        = st;
      have_prev = 1'b1;
    end
  endtask

  // --------------------------------------------------------------------------
  // Extension point for Option 2 (RTL FSM coverage). Call from a bind module or
  // the env once the DUT FSM signal and encoding are known; add a covergroup
  // here and construct it in new().
  // --------------------------------------------------------------------------
  function void sample_dut_fsm(int unsigned prev_state, int unsigned cur_state);
  endfunction

  // --------------------------------------------------------------------------
  // Reporting
  // --------------------------------------------------------------------------
  function real get_total_coverage();
    return (cg_txn.get_inst_coverage() + cg_err.get_inst_coverage() +
            cg_seq.get_inst_coverage() + cg_data.get_inst_coverage() +
            cg_fsm.get_inst_coverage()) / 5.0;
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (enforce_goal && get_total_coverage() < coverage_goal)
      `uvm_error("APB_COV_GOAL",
                 $sformatf("Functional coverage %0.2f%% below goal %0.2f%%",
                           get_total_coverage(), coverage_goal))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("APB_COV",
              $sformatf("items=%0d | txn=%0.2f%% err=%0.2f%% seq=%0.2f%% data=%0.2f%% fsm=%0.2f%% | total=%0.2f%% (goal %0.1f%%)",
                        num_items,
                        cg_txn.get_inst_coverage(),  cg_err.get_inst_coverage(),
                        cg_seq.get_inst_coverage(),  cg_data.get_inst_coverage(),
                        cg_fsm.get_inst_coverage(),  get_total_coverage(),
                        coverage_goal),
              UVM_LOW)
  endfunction

endclass : apb_coverage
