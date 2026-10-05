// -----------------------------------------------------------------------------
// apb_tests.sv : UVM tests (package apb_test_pkg). Compile after apb_pkg.
//
//   apb_smoke_test      : short write/read-back sanity run
//   apb_regression_test : directed + random closure run; enforces the coverage goal
//   apb_random_test     : constrained-random traffic, +NUM_ITEMS=<n> (default 500), seed it
//   apb_reset_test      : random traffic; use +MID_RESET_AT=<cycle> +MID_RESET_LEN=<cycles>
//
// Slave-side wait states: the slave ramp (0..MAX_WAIT) runs forever in the
// background in every test except apb_random_test (random wait states).
// -----------------------------------------------------------------------------
package apb_test_pkg;

  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_pkg::*;

  // ===========================================================================
  // Base test
  // ===========================================================================
  class apb_base_test extends uvm_test;

    localparam int unsigned AW = 32;
    localparam int unsigned DW = 32;

    typedef virtual apb_if       #(AW, DW) vif_t;
    typedef apb_env_config       #(AW, DW) env_cfg_t;
    typedef apb_agent_config     #(AW, DW) agt_cfg_t;
    typedef apb_env              #(AW, DW) env_t;
    typedef apb_slave_ramp_wait_seq   #(AW, DW) ramp_t;
    typedef apb_slave_random_wait_seq #(AW, DW) rwait_t;

    `uvm_component_utils(apb_base_test)

    env_t     env;
    env_cfg_t env_cfg;
    vif_t     vif;

    int unsigned drain_cycles = 20;
    time         watchdog     = 20ms;

    function new(string name = "apb_base_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // Derived tests override to tweak the configuration before the env is built
    virtual function void configure(env_cfg_t c);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
        `uvm_fatal("APB_TEST_NOVIF", "Virtual interface not set for the test (key \"vif\")")

      env_cfg         = env_cfg_t::type_id::create("env_cfg");
      env_cfg.agt_cfg = agt_cfg_t::type_id::create("agt_cfg");
      env_cfg.agt_cfg.vif = vif;
      configure(env_cfg);

      uvm_config_db #(env_cfg_t)::set(this, "env", "cfg", env_cfg);
      env = env_t::type_id::create("env", this);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction

    virtual function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      uvm_top.set_timeout(watchdog, 0);
    endfunction

    // ---- stimulus hooks -----------------------------------------------------
    virtual task run_master_traffic();
    endtask

    virtual task run_slave_traffic();
      ramp_t s;
      forever begin
        s = ramp_t::type_id::create("s_ramp");
        s.num_sweeps = 1;
        s.start(env.slv_agt.sqr);
      end
    endtask

    virtual task run_phase(uvm_phase phase);
      phase.raise_objection(this, "test running");
      wait (vif.PRESETn === 1'b1);
      repeat (2) @(posedge vif.PCLK);
      fork
        run_slave_traffic();
      join_none
      run_master_traffic();
      repeat (drain_cycles) @(posedge vif.PCLK);
      phase.drop_objection(this, "test done");
    endtask

    // Plusarg helper
    protected function int unsigned get_num_items(int unsigned dflt);
      int unsigned n;
      if ($value$plusargs("NUM_ITEMS=%d", n)) return n;
      return dflt;
    endfunction

  endclass : apb_base_test

  // ===========================================================================
  // Smoke
  // ===========================================================================
  class apb_smoke_test extends apb_base_test;
    typedef apb_master_wr_rd_seq #(AW, DW) wr_rd_t;
    `uvm_component_utils(apb_smoke_test)

    function new(string name = "apb_smoke_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual task run_master_traffic();
      wr_rd_t s = wr_rd_t::type_id::create("s_wr_rd");
      s.num_items = 8;
      s.start(env.mst_agt.sqr);
    endtask
  endclass : apb_smoke_test

  // ===========================================================================
  // Regression (closure)
  // ===========================================================================
  class apb_regression_test extends apb_base_test;
    typedef apb_master_regression_seq #(AW, DW) reg_t;
    `uvm_component_utils(apb_regression_test)

    function new(string name = "apb_regression_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void configure(env_cfg_t c);
      c.enforce_cov_goal = 1'b1;     // PRD: 100% closure
      c.cov_goal         = 100.0;
    endfunction

    virtual task run_master_traffic();
      reg_t s = reg_t::type_id::create("s_reg");
      s.start(env.mst_agt.sqr);
    endtask
  endclass : apb_regression_test

  // ===========================================================================
  // Constrained-random (seeded), random slave wait states
  // ===========================================================================
  class apb_random_test extends apb_base_test;
    typedef apb_master_rand_seq #(AW, DW) rand_t;
    `uvm_component_utils(apb_random_test)

    function new(string name = "apb_random_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual task run_slave_traffic();
      rwait_t s;
      forever begin
        s = rwait_t::type_id::create("s_rwait");
        s.num_items = 32;
        s.start(env.slv_agt.sqr);
      end
    endtask

    virtual task run_master_traffic();
      rand_t s = rand_t::type_id::create("s_rand");
      s.num_items = get_num_items(500);
      s.start(env.mst_agt.sqr);
    endtask
  endclass : apb_random_test

  // ===========================================================================
  // Reset in flight (tb_top pulses reset with +MID_RESET_AT / +MID_RESET_LEN)
  // ===========================================================================
  class apb_reset_test extends apb_random_test;
    `uvm_component_utils(apb_reset_test)

    function new(string name = "apb_reset_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual task run_master_traffic();
      rand_t s = rand_t::type_id::create("s_rand");
      s.num_items = get_num_items(400);
      s.start(env.mst_agt.sqr);
    endtask
  endclass : apb_reset_test

endpackage : apb_test_pkg
