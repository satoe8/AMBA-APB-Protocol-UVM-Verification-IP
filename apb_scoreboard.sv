// -----------------------------------------------------------------------------
// apb_scoreboard.sv : bus-level scoreboard (included inside apb_pkg)
//
// Inputs (analysis imps):
//   mon_imp  <- agent.ap       transfers observed on the bus (monitor)
//   resp_imp <- agent.resp_ap  responses decided/driven by the slave driver
//   exp_imp  <- (future) upstream predictor: EXPECTED apb_seq_item per transfer
//
// Checks per monitored transfer:
//   C1 PSLVERR matches an independently predicted error (address-map rules)
//   C2 Write integrity : driver's mem.peek() == scoreboard shadow after the write
//                        (errored writes must leave memory untouched)
//   C3 Read data       : PRDATA of an error-free read == shadow value built from
//                        monitored bus writes (independent of the driver memory)
//   C4 Monitor item vs driver item (item.compare(), plus wait-state count)
//   C5 Upstream compare (only when enable_upstream_check = 1)
// check_phase additionally fails on: interface SVA failures (vif.sva_fail_cnt),
// unmatched queue leftovers, and warns on a vacuous run (0 transfers).
//
// Backdoor preloads: use sb.preload(addr, data) so the shadow stays in sync with
// the driver memory (mem.poke() alone would show up as read-data mismatches).
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_apb_mon)
`uvm_analysis_imp_decl(_apb_resp)
`uvm_analysis_imp_decl(_apb_exp)

class apb_scoreboard #(int unsigned ADDR_WIDTH = 32,
                       int unsigned DATA_WIDTH = 32) extends uvm_scoreboard;

  localparam int unsigned STRB_W = DATA_WIDTH / 8;

  typedef apb_seq_item  #(ADDR_WIDTH, DATA_WIDTH)   item_t;
  typedef apb_mem_model #(ADDR_WIDTH, DATA_WIDTH)   mem_t;
  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH)  vif_t;
  typedef apb_scoreboard #(ADDR_WIDTH, DATA_WIDTH)  this_type;
  typedef bit [ADDR_WIDTH-1:0]                      addr_t;
  typedef bit [DATA_WIDTH-1:0]                      data_t;
  typedef bit [STRB_W-1:0]                          strb_t;

  `uvm_component_param_utils(apb_scoreboard #(ADDR_WIDTH, DATA_WIDTH))

  // --------------------------------------------------------------------------
  // Ports
  // --------------------------------------------------------------------------
  uvm_analysis_imp_apb_mon  #(item_t, this_type) mon_imp;
  uvm_analysis_imp_apb_resp #(item_t, this_type) resp_imp;
  uvm_analysis_imp_apb_exp  #(item_t, this_type) exp_imp;

  // --------------------------------------------------------------------------
  // Knobs / handles (set by the env before the run phase)
  // --------------------------------------------------------------------------
  mem_t mem;                              // agent.mem (optional; enables C2)
  bit   check_exp_error         = 1'b1;   // C1
  bit   check_write_integrity   = 1'b1;   // C2
  bit   check_read_data         = 1'b1;   // C3
  bit   check_resp_consistency  = 1'b1;   // C4
  bit   enable_upstream_check   = 1'b0;   // C5 (needs a predictor on exp_imp)
  bit   err_on_misaligned       = 1'b0;   // must match the memory model knob
  bit   clear_shadow_on_reset   = 1'b1;   // must match driver clear_mem_on_reset
  data_t default_data           = '0;     // used when mem == null

  // --------------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------------
  protected vif_t   vif;                  // optional: reset watch + SVA roll-up
  protected data_t  shadow [addr_t];
  protected item_t  mon_q[$], resp_q[$];  // C4 pairing
  protected item_t  obs_q[$], exp_q[$];   // C5 pairing
  protected bit     exp_warned = 1'b0;

  int unsigned num_mon          = 0;
  int unsigned num_resp         = 0;
  int unsigned num_exp          = 0;
  int unsigned num_err_chk      = 0;
  int unsigned num_wr_chk       = 0;
  int unsigned num_rd_chk       = 0;
  int unsigned num_resp_cmp     = 0;
  int unsigned num_exp_cmp      = 0;
  int unsigned num_resets       = 0;
  int unsigned err_cnt          = 0;

  // --------------------------------------------------------------------------
  function new(string name = "apb_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon_imp  = new("mon_imp",  this);
    resp_imp = new("resp_imp", this);
    exp_imp  = new("exp_imp",  this);
    if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
      `uvm_info("APB_SB", "No vif supplied: reset watch and SVA roll-up disabled", UVM_LOW)
  endfunction

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------
  protected function void flag_error(string id, string msg);
    err_cnt++;
    `uvm_error(id, msg)
  endfunction

  function int unsigned get_error_count();
    return err_cnt;
  endfunction

  protected function data_t get_default();
    return (mem != null) ? mem.default_data : default_data;
  endfunction

  protected function addr_t word_key(addr_t a);
    return a & ~addr_t'(STRB_W - 1);
  endfunction

  protected function data_t shadow_peek(addr_t a);
    addr_t k = word_key(a);
    return shadow.exists(k) ? shadow[k] : get_default();
  endfunction

  protected function void shadow_write(addr_t a, data_t d, strb_t s);
    data_t merged;
    merged = shadow_peek(a);
    for (int i = 0; i < STRB_W; i++)
      if (s[i]) merged[8*i +: 8] = d[8*i +: 8];
    shadow[word_key(a)] = merged;
  endfunction

  // Independent re-implementation of the slave's error rules
  protected function bit predict_error(addr_t a, bit write);
    if (a < item_t::map_lo || a > item_t::map_hi)           return 1'b1;
    if (write && a >= item_t::ro_lo && a <= item_t::ro_hi) return 1'b1;
    if (err_on_misaligned && ((a & addr_t'(STRB_W - 1)) != '0)) return 1'b1;
    return 1'b0;
  endfunction

  // Public: keep shadow and driver memory in sync for backdoor preloads
  function void preload(addr_t a, data_t d);
    shadow[word_key(a)] = d;
    if (mem != null) mem.poke(a, d);
  endfunction

  // --------------------------------------------------------------------------
  // Monitor input: C1, C2, C3, then queue for C4 / C5
  // --------------------------------------------------------------------------
  function void write_apb_mon(item_t t);
    num_mon++;
    check_monitored(t);
    if (check_resp_consistency) begin
      mon_q.push_back(t);
      match_resp();
    end
    if (enable_upstream_check) begin
      obs_q.push_back(t);
      match_exp();
    end
  endfunction

  protected function void check_monitored(item_t t);
    bit    exp_err;
    data_t exp_data;

    exp_err = predict_error(t.paddr, t.pwrite);

    // C1: expected PSLVERR
    if (check_exp_error) begin
      num_err_chk++;
      if (t.pslverr !== exp_err)
        flag_error("APB_SB_ERR",
                   $sformatf("PSLVERR mismatch: expected %0b, got %0b | %s",
                             exp_err, t.pslverr, t.convert2string()));
    end

    if (t.pwrite) begin
      // The golden model decides whether the write takes effect
      if (!exp_err) shadow_write(t.paddr, t.pwdata, t.pstrb);

      // C2: driver memory must agree with the shadow (also covers "errored
      //     write must not commit")
      if (check_write_integrity && mem != null) begin
        num_wr_chk++;
        if (mem.peek(t.paddr) !== shadow_peek(t.paddr))
          flag_error("APB_SB_WR",
                     $sformatf("Memory 0x%0h = 0x%0h but shadow = 0x%0h after | %s",
                               t.paddr, mem.peek(t.paddr), shadow_peek(t.paddr),
                               t.convert2string()));
      end
    end
    else if (check_read_data && !exp_err && !t.pslverr) begin
      // C3: read data against the bus-built shadow
      num_rd_chk++;
      exp_data = shadow_peek(t.paddr);
      if (t.prdata !== exp_data)
        flag_error("APB_SB_RD",
                   $sformatf("Read data mismatch: expected 0x%0h, got 0x%0h | %s",
                             exp_data, t.prdata, t.convert2string()));
    end
  endfunction

  // --------------------------------------------------------------------------
  // Driver input (C4)
  // --------------------------------------------------------------------------
  function void write_apb_resp(item_t t);
    num_resp++;
    if (check_resp_consistency) begin
      resp_q.push_back(t);
      match_resp();
    end
  endfunction

  protected function void match_resp();
    item_t m, r;
    while (mon_q.size() > 0 && resp_q.size() > 0) begin
      m = mon_q.pop_front();
      r = resp_q.pop_front();
      num_resp_cmp++;
      if (!m.compare(r))
        flag_error("APB_SB_CMP",
                   $sformatf("Monitor/driver item mismatch\n  monitor: %s\n  driver : %s",
                             m.convert2string(), r.convert2string()));
      else if (m.observed_wait_states != r.observed_wait_states)
        flag_error("APB_SB_WAIT",
                   $sformatf("Wait-state mismatch: bus showed %0d, slave planned %0d | %s",
                             m.observed_wait_states, r.observed_wait_states,
                             m.convert2string()));
    end
  endfunction

  // --------------------------------------------------------------------------
  // Upstream predictor hook (C5)
  // --------------------------------------------------------------------------
  function void write_apb_exp(item_t t);
    num_exp++;
    if (!enable_upstream_check) begin
      if (!exp_warned) begin
        exp_warned = 1'b1;
        `uvm_warning("APB_SB_EXP",
                     "Expected item received but enable_upstream_check = 0; ignoring")
      end
      return;
    end
    exp_q.push_back(t);
    match_exp();
  endfunction

  protected function void match_exp();
    item_t o, e;
    while (obs_q.size() > 0 && exp_q.size() > 0) begin
      o = obs_q.pop_front();
      e = exp_q.pop_front();
      num_exp_cmp++;
      if (!o.compare(e))
        flag_error("APB_SB_UPSTREAM",
                   $sformatf("Observed transfer differs from upstream prediction\n  observed : %s\n  predicted: %s",
                             o.convert2string(), e.convert2string()));
    end
  endfunction

  // --------------------------------------------------------------------------
  // Reset handling
  // --------------------------------------------------------------------------
  protected function void handle_reset();
    num_resets++;
    if (clear_shadow_on_reset) shadow.delete();
    obs_q.delete();
    exp_q.delete();
  endfunction

  virtual task run_phase(uvm_phase phase);
    if (vif == null) return;
    forever begin
      @(negedge vif.PRESETn);
      handle_reset();
    end
  endtask

  // --------------------------------------------------------------------------
  // End-of-test
  // --------------------------------------------------------------------------
  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);

    if (vif != null && vif.sva_fail_cnt != 0)
      flag_error("APB_SB_SVA",
                 $sformatf("%0d interface assertion failure(s) recorded", vif.sva_fail_cnt));

    if (mon_q.size() != 0)
      flag_error("APB_SB_LEFT",
                 $sformatf("%0d monitored transfer(s) never matched by the slave driver", mon_q.size()));
    if (resp_q.size() != 0)
      flag_error("APB_SB_LEFT",
                 $sformatf("%0d slave response(s) never matched by a monitored transfer", resp_q.size()));

    if (enable_upstream_check) begin
      if (obs_q.size() != 0)
        flag_error("APB_SB_LEFT",
                   $sformatf("%0d observed transfer(s) had no upstream prediction", obs_q.size()));
      if (exp_q.size() != 0)
        flag_error("APB_SB_LEFT",
                   $sformatf("%0d predicted transfer(s) were never observed on the bus", exp_q.size()));
    end

    if (num_mon == 0)
      `uvm_warning("APB_SB_VACUOUS", "No transfers observed: this run checked nothing")
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("APB_SB",
              $sformatf("mon=%0d resp=%0d exp=%0d | err-chk=%0d wr-chk=%0d rd-chk=%0d resp-cmp=%0d exp-cmp=%0d | resets=%0d errors=%0d",
                        num_mon, num_resp, num_exp, num_err_chk, num_wr_chk, num_rd_chk,
                        num_resp_cmp, num_exp_cmp, num_resets, err_cnt),
              UVM_LOW)
    if (err_cnt == 0 && num_mon != 0)
      `uvm_info("APB_SB", "*** APB SCOREBOARD: PASS ***", UVM_LOW)
    else
      `uvm_info("APB_SB", "*** APB SCOREBOARD: FAIL / INCONCLUSIVE ***", UVM_LOW)
  endfunction

endclass : apb_scoreboard
