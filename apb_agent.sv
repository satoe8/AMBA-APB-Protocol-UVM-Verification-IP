// -----------------------------------------------------------------------------
// apb_agent.sv : APB VIP agent, slave-responder role (included in apb_pkg)
//
//   ACTIVE : monitor + sequencer + slave driver
//   PASSIVE: monitor only
//
// Exposed to the env / scoreboard:
//   mem     : shared golden register-file model (valid after the agent's build_phase)
//   ap      : every transfer observed on the bus      (from the monitor)
//   resp_ap : every response the slave decided/drove  (from the driver, ACTIVE only)
//
// Config: uvm_config_db #(apb_agent_config #(A,D))::set(..., "cfg", cfg)
// -----------------------------------------------------------------------------
class apb_agent #(int unsigned ADDR_WIDTH = 32,
                  int unsigned DATA_WIDTH = 32) extends uvm_agent;

  typedef apb_seq_item          #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef apb_agent_config      #(ADDR_WIDTH, DATA_WIDTH) cfg_t;
  typedef apb_mem_model         #(ADDR_WIDTH, DATA_WIDTH) mem_t;
  typedef apb_monitor           #(ADDR_WIDTH, DATA_WIDTH) mon_t;
  typedef apb_slave_driver      #(ADDR_WIDTH, DATA_WIDTH) drv_t;
  typedef apb_slave_sequencer   #(ADDR_WIDTH, DATA_WIDTH) sqr_t;
  typedef virtual apb_if        #(ADDR_WIDTH, DATA_WIDTH) vif_t;

  `uvm_component_param_utils(apb_agent #(ADDR_WIDTH, DATA_WIDTH))

  cfg_t cfg;
  mon_t mon;
  drv_t drv;   // null when PASSIVE
  sqr_t sqr;   // null when PASSIVE
  mem_t mem;

  uvm_analysis_port #(item_t) ap;
  uvm_analysis_port #(item_t) resp_ap;

  function new(string name = "apb_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // --------------------------------------------------------------------------
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(cfg_t)::get(this, "", "cfg", cfg))
      `uvm_fatal("APB_AGT_NOCFG",
                 {"apb_agent_config not set for ", get_full_name(), ".cfg"})
    if (!cfg.is_valid())
      `uvm_fatal("APB_AGT_BADCFG", "Invalid apb_agent_config (see errors above)")

    is_active = cfg.is_active;
    cfg.apply_addr_map();

    ap      = new("ap", this);
    resp_ap = new("resp_ap", this);

    // Shared golden model: use the supplied one or create it here so the
    // handle is valid for the env as soon as this agent has been built.
    mem = (cfg.mem != null) ? cfg.mem : mem_t::type_id::create("mem");
    mem.default_data      = cfg.mem_default_data;
    mem.err_on_misaligned = cfg.err_on_misaligned;
    cfg.mem = mem;

    uvm_config_db #(vif_t)::set(this, "mon", "vif", cfg.vif);
    mon = mon_t::type_id::create("mon", this);

    if (get_is_active() == UVM_ACTIVE) begin
      uvm_config_db #(vif_t)::set(this, "drv", "vif", cfg.vif);
      uvm_config_db #(mem_t)::set(this, "drv", "mem", mem);

      sqr = sqr_t::type_id::create("sqr", this);
      drv = drv_t::type_id::create("drv", this);

      drv.default_wait            = cfg.default_wait;
      drv.plan_depth              = cfg.plan_depth;
      drv.randomize_rdata_in_wait = cfg.randomize_rdata_in_wait;
      drv.clear_mem_on_reset      = cfg.clear_mem_on_reset;
      sqr.mem                     = mem;
    end
  endfunction

  // --------------------------------------------------------------------------
  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.ap.connect(ap);
    if (get_is_active() == UVM_ACTIVE) begin
      drv.seq_item_port.connect(sqr.seq_item_export);
      drv.resp_ap.connect(resp_ap);
    end
  endfunction

endclass : apb_agent
