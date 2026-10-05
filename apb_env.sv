// -----------------------------------------------------------------------------
// apb_env.sv : environment config + environment (included inside apb_pkg)
//
// Topology (self-test mode, has_master = 1):
//
//   mst_agt (sqr + master drv) --drives--> apb_if <--responds-- slv_agt (sqr + slave drv + mon)
//
//   slv_agt.ap       -> sb.mon_imp , cov.analysis_export
//   slv_agt.resp_ap  -> sb.resp_imp
//   mst_agt.ap       -> sb.exp_imp  (stand-in upstream predictor; master_as_predictor)
//   sb.mem           =  slv_agt.mem (shared golden register-file model)
//
// With a real bridge DUT: set has_master = 0 and connect your upstream predictor to
// sb.exp_imp (enable_upstream_check = 1).
//
// Config: uvm_config_db #(apb_env_config #(A,D))::set(<test>, "env", "cfg", cfg)
// -----------------------------------------------------------------------------
class apb_env_config #(int unsigned ADDR_WIDTH = 32,
                       int unsigned DATA_WIDTH = 32) extends uvm_object;

  typedef apb_agent_config #(ADDR_WIDTH, DATA_WIDTH) agt_cfg_t;

  `uvm_object_param_utils(apb_env_config #(ADDR_WIDTH, DATA_WIDTH))

  agt_cfg_t agt_cfg;                    // shared by the slave and master agents

  bit  has_master           = 1'b1;     // self-test stimulus
  bit  has_scoreboard       = 1'b1;
  bit  has_coverage         = 1'b1;
  bit  master_as_predictor  = 1'b1;     // mst_agt.ap -> sb.exp_imp
  bit  enforce_cov_goal     = 1'b0;     // fail the run below cov_goal
  real cov_goal             = 100.0;

  function new(string name = "apb_env_config");
    super.new(name);
  endfunction

endclass : apb_env_config


class apb_env #(int unsigned ADDR_WIDTH = 32,
                int unsigned DATA_WIDTH = 32) extends uvm_env;

  typedef apb_env_config   #(ADDR_WIDTH, DATA_WIDTH) env_cfg_t;
  typedef apb_agent_config #(ADDR_WIDTH, DATA_WIDTH) agt_cfg_t;
  typedef apb_agent        #(ADDR_WIDTH, DATA_WIDTH) slv_agt_t;
  typedef apb_master_agent #(ADDR_WIDTH, DATA_WIDTH) mst_agt_t;
  typedef apb_scoreboard   #(ADDR_WIDTH, DATA_WIDTH) sb_t;
  typedef apb_coverage     #(ADDR_WIDTH, DATA_WIDTH) cov_t;
  typedef virtual apb_if   #(ADDR_WIDTH, DATA_WIDTH) vif_t;

  `uvm_component_param_utils(apb_env #(ADDR_WIDTH, DATA_WIDTH))

  env_cfg_t cfg;
  slv_agt_t slv_agt;
  mst_agt_t mst_agt;   // null when has_master = 0
  sb_t      sb;        // null when has_scoreboard = 0
  cov_t     cov;       // null when has_coverage = 0

  function new(string name = "apb_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // --------------------------------------------------------------------------
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(env_cfg_t)::get(this, "", "cfg", cfg))
      `uvm_fatal("APB_ENV_NOCFG", {"apb_env_config not set for ", get_full_name(), ".cfg"})
    if (cfg.agt_cfg == null)
      `uvm_fatal("APB_ENV_NOCFG", "apb_env_config.agt_cfg is null")

    uvm_config_db #(agt_cfg_t)::set(this, "slv_agt", "cfg", cfg.agt_cfg);
    slv_agt = slv_agt_t::type_id::create("slv_agt", this);

    if (cfg.has_master) begin
      uvm_config_db #(agt_cfg_t)::set(this, "mst_agt", "cfg", cfg.agt_cfg);
      mst_agt = mst_agt_t::type_id::create("mst_agt", this);
    end

    if (cfg.has_scoreboard) begin
      uvm_config_db #(vif_t)::set(this, "sb", "vif", cfg.agt_cfg.vif);
      sb = sb_t::type_id::create("sb", this);
    end

    if (cfg.has_coverage) begin
      uvm_config_db #(vif_t)::set(this, "cov", "vif", cfg.agt_cfg.vif);
      cov = cov_t::type_id::create("cov", this);
      cov.enforce_goal  = cfg.enforce_cov_goal;
      cov.coverage_goal = cfg.cov_goal;
    end
  endfunction

  // --------------------------------------------------------------------------
  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if (sb != null) begin
      slv_agt.ap.connect(sb.mon_imp);
      if (slv_agt.get_is_active() == UVM_ACTIVE)
        slv_agt.resp_ap.connect(sb.resp_imp);
      else
        sb.check_resp_consistency = 1'b0;      // no driver, no responses to pair

      sb.mem                   = slv_agt.mem;
      sb.clear_shadow_on_reset = cfg.agt_cfg.clear_mem_on_reset;
      sb.err_on_misaligned     = cfg.agt_cfg.err_on_misaligned;
      sb.default_data          = cfg.agt_cfg.mem_default_data;

      if (mst_agt != null && cfg.master_as_predictor) begin
        mst_agt.ap.connect(sb.exp_imp);
        sb.enable_upstream_check = 1'b1;
      end
    end

    if (cov != null)
      slv_agt.ap.connect(cov.analysis_export);
  endfunction

  // --------------------------------------------------------------------------
  // End-of-test roll-up of component-level health counters
  // --------------------------------------------------------------------------
  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (slv_agt.mon.num_proto_err != 0)
      `uvm_error("APB_ENV_MON",
                 $sformatf("Monitor detected %0d protocol/X violation(s)", slv_agt.mon.num_proto_err))
    if (mst_agt != null && mst_agt.drv.num_timeouts != 0)
      `uvm_error("APB_ENV_MST",
                 $sformatf("Master driver hit %0d PREADY timeout(s)", mst_agt.drv.num_timeouts))
  endfunction

endclass : apb_env
