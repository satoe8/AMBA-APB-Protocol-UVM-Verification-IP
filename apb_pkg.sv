// -----------------------------------------------------------------------------
// apb_pkg.sv : AMBA APB (APB4) UVM VIP package
// Enums live at package scope so every parameterization of apb_seq_item shares
// the same enum types (enums declared inside a parameterized class would be
// distinct types per specialization).
// -----------------------------------------------------------------------------
`ifndef APB_PKG_SV
`define APB_PKG_SV

package apb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Intent of the generated address (used by constraints, coverage, scoreboard)
  typedef enum {
    ADDR_VALID,      // mapped, read/write-able region
    ADDR_PROTECTED,  // mapped, read-only / protected region (error coverage)
    ADDR_UNMAPPED,   // beyond the mapped window (decode error expected)
    ADDR_BOUNDARY    // region edges: first/last word, one-below/one-above
  } apb_addr_kind_e;

  // Intent of the generated write payload
  typedef enum {
    DATA_RANDOM,
    DATA_WALK_1,     // single 1 walking across the bus
    DATA_WALK_0,     // single 0 walking across the bus
    DATA_ALT_AA,     // 1010...
    DATA_ALT_55,     // 0101...
    DATA_MIN,        // all zeros
    DATA_MAX         // all ones
  } apb_data_kind_e;

  `include "apb_seq_item.sv"
  `include "apb_monitor.sv"
  `include "apb_mem_model.sv"
  `include "apb_slave_driver.sv"
  `include "apb_agent_config.sv"
  `include "apb_slave_sequencer.sv"
  `include "apb_agent.sv"
  `include "apb_master_driver.sv"
  `include "apb_master_agent.sv"
  `include "apb_slave_seq_lib.sv"
  `include "apb_scoreboard.sv"
  `include "apb_coverage.sv"

endpackage : apb_pkg

`endif // APB_PKG_SV// -----------------------------------------------------------------------------
// apb_pkg.sv : AMBA APB (APB4) UVM VIP package
// Enums live at package scope so every parameterization of apb_seq_item shares
// the same enum types (enums declared inside a parameterized class would be
// distinct types per specialization).
// -----------------------------------------------------------------------------
`ifndef APB_PKG_SV
`define APB_PKG_SV

package apb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Intent of the generated address (used by constraints, coverage, scoreboard)
  typedef enum {
    ADDR_VALID,      // mapped, read/write-able region
    ADDR_PROTECTED,  // mapped, read-only / protected region (error coverage)
    ADDR_UNMAPPED,   // beyond the mapped window (decode error expected)
    ADDR_BOUNDARY    // region edges: first/last word, one-below/one-above
  } apb_addr_kind_e;

  // Intent of the generated write payload
  typedef enum {
    DATA_RANDOM,
    DATA_WALK_1,     // single 1 walking across the bus
    DATA_WALK_0,     // single 0 walking across the bus
    DATA_ALT_AA,     // 1010...
    DATA_ALT_55,     // 0101...
    DATA_MIN,        // all zeros
    DATA_MAX         // all ones
  } apb_data_kind_e;

  `include "apb_seq_item.sv"
  `include "apb_monitor.sv"
  `include "apb_mem_model.sv"
  `include "apb_slave_driver.sv"
  `include "apb_agent_config.sv"
  `include "apb_slave_sequencer.sv"
  `include "apb_agent.sv"
  `include "apb_slave_seq_lib.sv"
  `include "apb_scoreboard.sv"
  `include "apb_coverage.sv"

endpackage : apb_pkg

`endif // APB_PKG_SV