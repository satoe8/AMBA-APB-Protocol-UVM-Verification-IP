// -----------------------------------------------------------------------------
// apb_master_seq_lib.sv : master-side stimulus (included inside apb_pkg)
//
// All sequences run on uvm_sequencer #(apb_seq_item) (the master agent's sqr) and
// generate items through the item's own constraints (randomize() with {...}).
// The base-class send() task pins down only what a given sequence cares about;
// everything else stays constrained-random.
//
//   apb_master_rand_seq        : fully constrained-random mix           (PRD 3.1)
//   apb_master_wr_rd_seq       : write then read back the same address   (data path)
//   apb_master_walk_seq        : walking-1/0, alt AA/55, min/max, random patterns,
//                                each written (full strobes) and read back (PRD 3.1)
//   apb_master_addr_seq        : valid / protected / unmapped x read/write (PRD 3.1, 4.1)
//   apb_master_boundary_seq    : region edges x read/write                 (PRD 3.1)
//   apb_master_burst_sweep_seq : back-to-back runs of length 1..12          (PRD 3.2)
//   apb_master_turnaround_seq  : every R/W turnaround x idle gap 0..3       (PRD 3.2)
//   apb_master_regression_seq  : all of the above in order
//
// Closure note: addr_seq (6 items per rep) and boundary_seq (10 items per rep) use
// reps = 17, coprime with the 17-value slave ramp (0..MAX_WAIT). With the ramp
// running in the background every (address, direction) item meets every wait value.
// -----------------------------------------------------------------------------

// =============================================================================
// Base
// =============================================================================
class apb_master_base_seq #(int unsigned ADDR_WIDTH = 32,
                            int unsigned DATA_WIDTH = 32)
  extends uvm_sequence #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef bit [ADDR_WIDTH-1:0]                   addr_t;

  `uvm_object_param_utils(apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned num_items = 16;

  protected addr_t       last_addr;
  protected int unsigned stamp_len = 1;   // burst metadata stamped on items
  protected int unsigned stamp_idx = 0;

  function new(string name = "apb_master_base_seq");
    super.new(name);
  endfunction

  // Send one transfer. Every *_rand flag left at 1 keeps that field random.
  protected task send(input bit              wr_rand   = 1'b1,
                      input bit              wr        = 1'b0,
                      input bit              idle_rand = 1'b1,
                      input int unsigned     idle      = 0,
                      input bit              kind_rand = 1'b1,
                      input apb_addr_kind_e  kind      = ADDR_VALID,
                      input bit              data_rand = 1'b1,
                      input apb_data_kind_e  dk        = DATA_RANDOM,
                      input int unsigned     widx      = 0,
                      input bit              full_strb = 1'b0,
                      input bit              use_addr  = 1'b0,
                      input addr_t           a         = '0);
    item_t it;
    it = item_t::type_id::create("it");
    start_item(it);
    if (!it.randomize() with {
          (!local::wr_rand)   -> (pwrite == local::wr);
          (!local::idle_rand) -> (idle_cycles == local::idle);
          (!local::kind_rand) -> (addr_kind == local::kind);
          (!local::data_rand) -> (data_kind == local::dk && walk_idx == local::widx);
          (local::full_strb && pwrite) -> (pstrb == item_t::STRB_ALL);
          (local::use_addr)   -> (paddr == local::a);
        })
      `uvm_fatal("APB_MSEQ_RAND", "Randomization of master item failed")
    it.burst_len = stamp_len;
    it.burst_idx = stamp_idx;
    last_addr    = it.paddr;
    finish_item(it);
  endtask

endclass : apb_master_base_seq

// =============================================================================
// Fully random
// =============================================================================
class apb_master_rand_seq #(int unsigned ADDR_WIDTH = 32,
                            int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_master_rand_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_master_rand_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_items) send();
  endtask

endclass : apb_master_rand_seq

// =============================================================================
// Write then read back the same (valid) address
// =============================================================================
class apb_master_wr_rd_seq #(int unsigned ADDR_WIDTH = 32,
                             int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef bit [ADDR_WIDTH-1:0] addr_t;

  `uvm_object_param_utils(apb_master_wr_rd_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_master_wr_rd_seq");
    super.new(name);
  endfunction

  virtual task body();
    addr_t a;
    repeat (num_items) begin
      send(.wr_rand(1'b0), .wr(1'b1), .kind_rand(1'b0), .kind(ADDR_VALID));
      a = last_addr;
      send(.wr_rand(1'b0), .wr(1'b0), .kind_rand(1'b0), .kind(ADDR_VALID),
           .use_addr(1'b1), .a(a));
    end
  endtask

endclass : apb_master_wr_rd_seq

// =============================================================================
// Data patterns: each pattern written with full strobes, then read back
// =============================================================================
class apb_master_walk_seq #(int unsigned ADDR_WIDTH = 32,
                            int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef bit [ADDR_WIDTH-1:0] addr_t;

  `uvm_object_param_utils(apb_master_walk_seq #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_master_walk_seq");
    super.new(name);
  endfunction

  protected task wr_rd_pattern(apb_data_kind_e dk, int unsigned widx);
    addr_t a;
    send(.wr_rand(1'b0), .wr(1'b1), .kind_rand(1'b0), .kind(ADDR_VALID),
         .data_rand(1'b0), .dk(dk), .widx(widx), .full_strb(1'b1));
    a = last_addr;
    send(.wr_rand(1'b0), .wr(1'b0), .kind_rand(1'b0), .kind(ADDR_VALID),
         .use_addr(1'b1), .a(a));
  endtask

  virtual task body();
    for (int unsigned i = 0; i < DATA_WIDTH; i++) wr_rd_pattern(DATA_WALK_1, i);
    for (int unsigned i = 0; i < DATA_WIDTH; i++) wr_rd_pattern(DATA_WALK_0, i);
    wr_rd_pattern(DATA_ALT_AA, 0);
    wr_rd_pattern(DATA_ALT_55, 0);
    wr_rd_pattern(DATA_MIN,    0);
    wr_rd_pattern(DATA_MAX,    0);
    wr_rd_pattern(DATA_RANDOM, 0);
  endtask

endclass : apb_master_walk_seq

// =============================================================================
// Address classes x direction (valid / protected / unmapped)
// =============================================================================
class apb_master_addr_seq #(int unsigned ADDR_WIDTH = 32,
                            int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_master_addr_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned reps = 17;   // 6 items per rep; coprime with the 17-value wait ramp

  function new(string name = "apb_master_addr_seq");
    super.new(name);
  endfunction

  virtual task body();
    apb_addr_kind_e kinds[3];
    kinds = '{ADDR_VALID, ADDR_PROTECTED, ADDR_UNMAPPED};
    repeat (reps)
      foreach (kinds[k])
        for (int d = 0; d < 2; d++)
          send(.wr_rand(1'b0), .wr(bit'(d)), .kind_rand(1'b0), .kind(kinds[k]));
  endtask

endclass : apb_master_addr_seq

// =============================================================================
// Region edges x direction
// =============================================================================
class apb_master_boundary_seq #(int unsigned ADDR_WIDTH = 32,
                                int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef bit [ADDR_WIDTH-1:0]                   addr_t;

  `uvm_object_param_utils(apb_master_boundary_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned reps = 17;   // 10 items per rep; coprime with the 17-value wait ramp

  function new(string name = "apb_master_boundary_seq");
    super.new(name);
  endfunction

  virtual task body();
    addr_t edges[5];
    // Must match the ADDR_BOUNDARY set in apb_seq_item::c_addr
    edges[0] = item_t::map_lo;
    edges[1] = item_t::map_hi;
    edges[2] = item_t::ro_lo;
    edges[3] = item_t::ro_lo - addr_t'(1);
    edges[4] = item_t::map_hi + addr_t'(1);
    repeat (reps)
      foreach (edges[i])
        for (int d = 0; d < 2; d++)
          send(.wr_rand(1'b0), .wr(bit'(d)), .kind_rand(1'b0), .kind(ADDR_BOUNDARY),
               .use_addr(1'b1), .a(edges[i]));
  endtask

endclass : apb_master_boundary_seq

// =============================================================================
// Back-to-back runs of length 1..12 (gap of 2 idle cycles between runs)
// =============================================================================
class apb_master_burst_sweep_seq #(int unsigned ADDR_WIDTH = 32,
                                   int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_master_burst_sweep_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned reps = 2;   // >= 2 so that both directions meet every run position

  function new(string name = "apb_master_burst_sweep_seq");
    super.new(name);
  endfunction

  virtual task body();
    int unsigned lens[8];
    int unsigned burst_no = 0;
    lens = '{1, 2, 3, 4, 5, 8, 9, 12};
    repeat (reps)
      foreach (lens[l]) begin
        for (int unsigned i = 0; i < lens[l]; i++) begin
          stamp_len = lens[l];
          stamp_idx = i;
          send(.wr_rand(1'b0), .wr(bit'((i + burst_no) % 2)),   // direction alternates
               .idle_rand(1'b0), .idle((i == 0) ? 2 : 0));       // idle 0 => back-to-back
        end
        burst_no++;
      end
    stamp_len = 1;
    stamp_idx = 0;
  endtask

endclass : apb_master_burst_sweep_seq

// =============================================================================
// Every previous-direction x direction turnaround at idle gaps 0, 1, 2, 3
// =============================================================================
class apb_master_turnaround_seq #(int unsigned ADDR_WIDTH = 32,
                                  int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  `uvm_object_param_utils(apb_master_turnaround_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned reps = 1;

  function new(string name = "apb_master_turnaround_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (reps)
      for (int pd = 0; pd < 2; pd++)
        for (int d = 0; d < 2; d++)
          for (int unsigned gap = 0; gap < 4; gap++) begin
            send(.wr_rand(1'b0), .wr(bit'(pd)), .idle_rand(1'b0), .idle(2));
            send(.wr_rand(1'b0), .wr(bit'(d)),  .idle_rand(1'b0), .idle(gap));
          end
  endtask

endclass : apb_master_turnaround_seq

// =============================================================================
// Composite regression
// =============================================================================
class apb_master_regression_seq #(int unsigned ADDR_WIDTH = 32,
                                  int unsigned DATA_WIDTH = 32)
  extends apb_master_base_seq #(ADDR_WIDTH, DATA_WIDTH);

  typedef apb_master_walk_seq        #(ADDR_WIDTH, DATA_WIDTH) walk_t;
  typedef apb_master_wr_rd_seq       #(ADDR_WIDTH, DATA_WIDTH) wr_rd_t;
  typedef apb_master_addr_seq        #(ADDR_WIDTH, DATA_WIDTH) addr_t_seq;
  typedef apb_master_boundary_seq    #(ADDR_WIDTH, DATA_WIDTH) bnd_t;
  typedef apb_master_burst_sweep_seq #(ADDR_WIDTH, DATA_WIDTH) burst_t;
  typedef apb_master_turnaround_seq  #(ADDR_WIDTH, DATA_WIDTH) turn_t;
  typedef apb_master_rand_seq        #(ADDR_WIDTH, DATA_WIDTH) rand_t;

  `uvm_object_param_utils(apb_master_regression_seq #(ADDR_WIDTH, DATA_WIDTH))

  int unsigned num_random = 200;

  function new(string name = "apb_master_regression_seq");
    super.new(name);
  endfunction

  virtual task body();
    walk_t     s_walk;
    wr_rd_t    s_wr_rd;
    addr_t_seq s_addr;
    bnd_t      s_bnd;
    burst_t    s_burst;
    turn_t     s_turn;
    rand_t     s_rand;

    s_walk  = walk_t::type_id::create("s_walk");
    s_wr_rd = wr_rd_t::type_id::create("s_wr_rd");
    s_addr  = addr_t_seq::type_id::create("s_addr");
    s_bnd   = bnd_t::type_id::create("s_bnd");
    s_burst = burst_t::type_id::create("s_burst");
    s_turn  = turn_t::type_id::create("s_turn");
    s_rand  = rand_t::type_id::create("s_rand");

    s_wr_rd.num_items = 64;
    s_rand.num_items  = num_random;

    s_walk.start(m_sequencer, this);
    s_wr_rd.start(m_sequencer, this);
    s_addr.start(m_sequencer, this);
    s_bnd.start(m_sequencer, this);
    s_burst.start(m_sequencer, this);
    s_turn.start(m_sequencer, this);
    s_rand.start(m_sequencer, this);
  endtask

endclass : apb_master_regression_seq
