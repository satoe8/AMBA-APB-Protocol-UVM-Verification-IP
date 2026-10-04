// -----------------------------------------------------------------------------
// apb_slave_sequencer.sv : sequencer for slave plan items (included in apb_pkg)
//
// Sequences access the slave's golden model through p_sequencer.mem, e.g. to
// preload read-only registers with mem.poke() before traffic starts.
// -----------------------------------------------------------------------------
class apb_slave_sequencer #(int unsigned ADDR_WIDTH = 32,
                            int unsigned DATA_WIDTH = 32)
  extends uvm_sequencer #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_mem_model #(ADDR_WIDTH, DATA_WIDTH) mem_t;

  `uvm_component_param_utils(apb_slave_sequencer #(ADDR_WIDTH, DATA_WIDTH))

  mem_t mem;   // set by apb_agent

  function new(string name = "apb_slave_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : apb_slave_sequencer
