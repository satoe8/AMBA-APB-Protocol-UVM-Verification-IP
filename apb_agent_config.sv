// -----------------------------------------------------------------------------
// apb_agent_config.sv : configuration object for apb_agent (included in apb_pkg)
//
// The env/test creates one, fills in `vif`, and sets it with
//   uvm_config_db #(apb_agent_config #(A,D))::set(this, "<agent path>", "cfg", cfg);
//
// NOTE: the address map lives in static members of apb_seq_item, so it is shared
// by every agent of the same <ADDR_WIDTH, DATA_WIDTH> specialization.
// -----------------------------------------------------------------------------
class apb_agent_config #(int unsigned ADDR_WIDTH = 32,
                         int unsigned DATA_WIDTH = 32) extends uvm_object;

  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH)  vif_t;
  typedef apb_mem_model  #(ADDR_WIDTH, DATA_WIDTH)  mem_t;
  typedef apb_seq_item   #(ADDR_WIDTH, DATA_WIDTH)  item_t;
  typedef bit [ADDR_WIDTH-1:0]                      addr_t;
  typedef bit [DATA_WIDTH-1:0]                      data_t;

  `uvm_object_param_utils(apb_agent_config #(ADDR_WIDTH, DATA_WIDTH))

  // Required
  vif_t                   vif;

  // Optional: pre-created shared model (agent creates one if left null)
  mem_t                   mem;

  uvm_active_passive_enum is_active = UVM_ACTIVE;

  // Address map (applied to apb_seq_item statics by the agent)
  addr_t map_lo = 'h0000_0000;
  addr_t map_hi = 'h0000_0FFF;
  addr_t ro_lo  = 'h0000_0F00;
  addr_t ro_hi  = 'h0000_0FFF;

  // Slave-driver knobs
  int unsigned default_wait            = 0;
  int unsigned plan_depth              = 2;      // must be >= 1
  bit          randomize_rdata_in_wait = 1'b1;
  bit          clear_mem_on_reset      = 1'b1;

  // Master-driver knobs (used by apb_master_agent)
  int unsigned master_timeout_cycles   = 1000;   // PREADY wait limit before abort
  bit          master_send_responses   = 1'b0;   // put_response() completed items

  // Memory-model knobs
  data_t       mem_default_data        = '0;
  bit          err_on_misaligned       = 1'b0;

  function new(string name = "apb_agent_config");
    super.new(name);
  endfunction

  function void apply_addr_map();
    item_t::set_addr_map(map_lo, map_hi, ro_lo, ro_hi);
  endfunction

  // Returns 1 when the configuration is usable; reports every problem found.
  function bit is_valid();
    bit ok = 1'b1;
    if (vif == null) begin
      `uvm_error("APB_CFG", "vif is null")
      ok = 1'b0;
    end
    if (map_lo > map_hi) begin
      `uvm_error("APB_CFG", "map_lo > map_hi")
      ok = 1'b0;
    end
    if (ro_lo > ro_hi) begin
      `uvm_error("APB_CFG", "ro_lo > ro_hi")
      ok = 1'b0;
    end
    if (ro_lo < map_lo || ro_hi > map_hi)
      `uvm_warning("APB_CFG", "Protected window extends outside the mapped window")
    if (plan_depth < 1) begin
      `uvm_error("APB_CFG", "plan_depth must be >= 1")
      ok = 1'b0;
    end
    return ok;
  endfunction

endclass : apb_agent_config