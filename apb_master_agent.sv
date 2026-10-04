// -----------------------------------------------------------------------------
// apb_master_agent.sv : APB master-role agent (included inside apb_pkg)
//
// Sequencer + master driver only: observation is done by the slave-role agent's
// monitor on the same interface, so a second monitor is deliberately NOT built.
// Used as the stand-in DUT stimulus for self-contained VIP verification; `ap`
// can feed the scoreboard's exp_imp (enable_upstream_check = 1).
//
// Config: uvm_config_db #(apb_agent_config #(A,D))::set(..., "cfg", cfg)
//         (vif, address map and master knobs are read from it)
// -----------------------------------------------------------------------------
class apb_master_agent #(int unsigned ADDR_WIDTH = 32,
                         int unsigned DATA_WIDTH = 32) extends uvm_agent;

  typedef apb_seq_item         #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef apb_agent_config     #(ADDR_WIDTH, DATA_WIDTH) cfg_t;
  typedef apb_master_driver    #(ADDR_WIDTH, DATA_WIDTH) drv_t;
  typedef uvm_sequencer        #(item_t)                 sqr_t;
  typedef virtual apb_if       #(ADDR_WIDTH, DATA_WIDTH) vif_t;

  `uvm_component_param_utils(apb_master_agent #(ADDR_WIDTH, DATA_WIDTH))

  cfg_t cfg;
  drv_t drv;
  sqr_t sqr;

  uvm_analysis_port #(item_t) ap;   // every completed master transfer

  function new(string name = "apb_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(cfg_t)::get(this, "", "cfg", cfg))
      `uvm_fatal("APB_MAG_NOCFG",
                 {"apb_agent_config not set for ", get_full_name(), ".cfg"})
    if (!cfg.is_valid())
      `uvm_fatal("APB_MAG_BADCFG", "Invalid apb_agent_config (see errors above)")

    is_active = UVM_ACTIVE;
    cfg.apply_addr_map();            // idempotent; item constraints use this map
    ap = new("ap", this);

    uvm_config_db #(vif_t)::set(this, "drv", "vif", cfg.vif);
    sqr = sqr_t::type_id::create("sqr", this);
    drv = drv_t::type_id::create("drv", this);

    drv.timeout_cycles = cfg.master_timeout_cycles;
    drv.send_responses = cfg.master_send_responses;
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    drv.ap.connect(ap);
  endfunction

endclass : apb_master_agent
