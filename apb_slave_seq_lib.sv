// -----------------------------------------------------------------------------
// apb_slave_seq_lib.sv : wait-state sequences for the slave driver
//                        (included in apb_pkg, after apb_slave_sequencer)
//
// Each item is a "plan" for ONE transfer; the driver only consumes
// item.wait_states. A sequence completes once the driver has pulled its last
// item, which requires the DUT to keep issuing transfers. Run these in the
// background (fork ... join_none) and let the master-side stimulus end the test.
//
//   apb_slave_zero_wait_seq   : all transfers with 0 wait states
//   apb_slave_fixed_wait_seq  : every transfer with wait_n wait states
//   apb_slave_random_wait_seq : randomized via item c_timing, optional min/max
//   apb_slave_ramp_wait_seq   : sweeps 0..MAX_WAIT (guarantees every wait bin)
//   apb_slave_alt_wait_seq    : alternates 0 and MAX_WAIT (stall/recover stress)
//   apb_slave_regression_seq  : runs all of the above in order
// -----------------------------------------------------------------------------

// =============================================================================
// Base
// =============================================================================
class apb_slave_base_seq #(int unsigned ADDR_WIDTH = 32,
                           int unsigned DATA_WIDTH = 32)
  extends uvm_sequence #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_seq_item        #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef apb_slave_sequencer #(ADDR_WIDTH, DATA_WIDTH) sqr_t;

  `uvm_object_param_utils(apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH))
  `uvm_declare_p_sequencer(sqr_t)

  int unsigned num_items = 16;

  function new(string name = "apb_slave_base_seq");
    super.new(name);
  endfunction

  // Send one plan item with an explicit wait count
  protected task send_wait(int unsigned w);
    item_t it;
    it = item_t::type_id::create("plan");
    start_item(it);
    it.wait_states = w;
    finish_item(it);
  endtask

endclass : apb_slave_base_seq

// =============================================================================
// Zero wait states (minimum two-cycle transfers)
// =============================================================================
class apb_slave_zero_wait_seq #(int unsigned ADDR_WIDTH = 32,
                                int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_slave_zero_wait_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_slave_zero_wait_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_items) send_wait(0);
  endtask

endclass : apb_slave_zero_wait_seq

// =============================================================================
// Fixed wait count
// =============================================================================
class apb_slave_fixed_wait_seq #(int unsigned ADDR_WIDTH = 32,
                                 int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_slave_fixed_wait_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned wait_n = 3;

  function new(string name = "apb_slave_fixed_wait_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_items) send_wait(wait_n);
  endtask

endclass : apb_slave_fixed_wait_seq

// =============================================================================
// Random wait count (uses the item's c_timing distribution)
// =============================================================================
class apb_slave_random_wait_seq #(int unsigned ADDR_WIDTH = 32,
                                  int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;

  `uvm_object_param_utils(apb_slave_random_wait_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned min_wait = 0;
  int unsigned max_wait = item_t::MAX_WAIT;

  function new(string name = "apb_slave_random_wait_seq");
    super.new(name);
  endfunction

  virtual task body();
    item_t it;
    repeat (num_items) begin
      it = item_t::type_id::create("plan");
      start_item(it);
      if (!it.randomize() with { wait_states inside {[local::min_wait : local::max_wait]}; })
        `uvm_fatal("APB_SEQ_RAND", "Randomization of wait-state plan item failed")
      finish_item(it);
    end
  endtask

endclass : apb_slave_random_wait_seq

// =============================================================================
// Ramp: 0, 1, 2, ... MAX_WAIT  (num_sweeps times)
// =============================================================================
class apb_slave_ramp_wait_seq #(int unsigned ADDR_WIDTH = 32,
                                int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;

  `uvm_object_param_utils(apb_slave_ramp_wait_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned num_sweeps = 1;

  function new(string name = "apb_slave_ramp_wait_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_sweeps)
      for (int unsigned w = 0; w <= item_t::MAX_WAIT; w++)
        send_wait(w);
  endtask

endclass : apb_slave_ramp_wait_seq

// =============================================================================
// Alternating 0 / MAX_WAIT  (num_items = number of pairs)
// =============================================================================
class apb_slave_alt_wait_seq #(int unsigned ADDR_WIDTH = 32,
                               int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;

  `uvm_object_param_utils(apb_slave_alt_wait_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_slave_alt_wait_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_items) begin
      send_wait(0);
      send_wait(item_t::MAX_WAIT);
    end
  endtask

endclass : apb_slave_alt_wait_seq

// =============================================================================
// Composite regression: zero -> ramp -> alternating -> random -> fixed
// =============================================================================
class apb_slave_regression_seq #(int unsigned ADDR_WIDTH = 32,
                                 int unsigned DATA_WIDTH = 32)
  extends apb_slave_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_slave_zero_wait_seq   #(ADDR_WIDTH, DATA_WIDTH) zero_t;
  typedef apb_slave_ramp_wait_seq   #(ADDR_WIDTH, DATA_WIDTH) ramp_t;
  typedef apb_slave_alt_wait_seq    #(ADDR_WIDTH, DATA_WIDTH) alt_t;
  typedef apb_slave_random_wait_seq #(ADDR_WIDTH, DATA_WIDTH) rand_t;
  typedef apb_slave_fixed_wait_seq  #(ADDR_WIDTH, DATA_WIDTH) fixed_t;

  `uvm_object_param_utils(apb_slave_regression_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_slave_regression_seq");
    super.new(name);
  endfunction

  virtual task body();
    zero_t  s_zero;
    ramp_t  s_ramp;
    alt_t   s_alt;
    rand_t  s_rand;
    fixed_t s_fixed;

    s_zero  = zero_t::type_id::create("s_zero");
    s_ramp  = ramp_t::type_id::create("s_ramp");
    s_alt   = alt_t::type_id::create("s_alt");
    s_rand  = rand_t::type_id::create("s_rand");
    s_fixed = fixed_t::type_id::create("s_fixed");

    s_zero.num_items  = 8;
    s_alt.num_items   = 4;
    s_rand.num_items  = 32;
    s_fixed.num_items = 8;
    s_fixed.wait_n    = 3;

    s_zero.start(m_sequencer, this);
    s_ramp.start(m_sequencer, this);
    s_alt.start(m_sequencer, this);
    s_rand.start(m_sequencer, this);
    s_fixed.start(m_sequencer, this);
  endtask

endclass : apb_slave_regression_seq
