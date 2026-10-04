// -----------------------------------------------------------------------------
// apb_seq_item.sv : APB transaction (included inside apb_pkg)
//
// Stimulus fields   : rand, set by sequences, consumed by the driver
// Response fields   : non-rand, filled by driver/monitor from the bus
// Metadata fields   : non-rand, stamped by sequences for coverage / debug
//
// Requires DATA_WIDTH to be a multiple of 8 and even (alternating patterns),
// and ADDR_WIDTH >= 13 for the default address map below.
// -----------------------------------------------------------------------------
class apb_seq_item #(int unsigned ADDR_WIDTH = 32,
                     int unsigned DATA_WIDTH = 32) extends uvm_sequence_item;

  // --------------------------------------------------------------------------
  // Local types / parameters
  // --------------------------------------------------------------------------
  localparam int unsigned STRB_W   = DATA_WIDTH / 8;
  localparam int unsigned MAX_WAIT = 16;   // max PREADY-low cycles injected
  localparam int unsigned MAX_IDLE = 4;    // max idle cycles between transfers

  typedef bit [ADDR_WIDTH-1:0] addr_t;
  typedef bit [DATA_WIDTH-1:0] data_t;
  typedef bit [STRB_W-1:0]     strb_t;
  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) this_type;

  localparam addr_t ADDR_MAX = '1;
  localparam strb_t STRB_ALL = '1;

  // --------------------------------------------------------------------------
  // Address map knobs (shared by all items of this specialization).
  // Override from the test via apb_seq_item#(..)::set_addr_map(...).
  // --------------------------------------------------------------------------
  static addr_t map_lo = 'h0000_0000;  // mapped window
  static addr_t map_hi = 'h0000_0FFF;
  static addr_t ro_lo  = 'h0000_0F00;  // protected / read-only sub-window
  static addr_t ro_hi  = 'h0000_0FFF;

  static function void set_addr_map(addr_t lo, addr_t hi, addr_t r_lo, addr_t r_hi);
    map_lo = lo;
    map_hi = hi;
    ro_lo  = r_lo;
    ro_hi  = r_hi;
  endfunction

  // --------------------------------------------------------------------------
  // Stimulus (randomized)
  // --------------------------------------------------------------------------
  rand addr_t          paddr;
  rand bit             pwrite;        // 1 = write, 0 = read
  rand data_t          pwdata;
  rand strb_t          pstrb;         // APB4 write strobes (0 on reads)
  rand bit [2:0]       pprot;         // APB4 protection
  rand int unsigned    wait_states;   // PREADY-low cycles during ACCESS
  rand int unsigned    idle_cycles;   // idle cycles BEFORE this transfer (0 = back-to-back)

  rand apb_addr_kind_e addr_kind;     // intent knobs: also sampled by coverage
  rand apb_data_kind_e data_kind;
  rand int unsigned    walk_idx;      // bit position for walking patterns

  // --------------------------------------------------------------------------
  // Response (observed on the bus)
  // --------------------------------------------------------------------------
  data_t               prdata;
  bit                  pslverr;
  int unsigned         observed_wait_states;

  // --------------------------------------------------------------------------
  // Metadata (not protocol fields; APB has no bursts: sequences emulate them)
  // --------------------------------------------------------------------------
  int unsigned         burst_len = 1;
  int unsigned         burst_idx = 0;
  bit                  allow_unaligned = 0; // tests may set 1 to probe misalignment

  // --------------------------------------------------------------------------
  // Factory registration
  // --------------------------------------------------------------------------
  `uvm_object_param_utils(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH))

  // --------------------------------------------------------------------------
  // Constraints
  // --------------------------------------------------------------------------
  constraint c_addr {
    solve addr_kind before paddr;

    addr_kind dist { ADDR_VALID     := 55,
                     ADDR_PROTECTED := 15,
                     ADDR_UNMAPPED  := 15,
                     ADDR_BOUNDARY  := 15 };

    (addr_kind == ADDR_VALID)     -> (paddr inside {[map_lo:map_hi]} &&
                                      !(paddr inside {[ro_lo:ro_hi]}));
    (addr_kind == ADDR_PROTECTED) -> (paddr inside {[ro_lo:ro_hi]});
    (addr_kind == ADDR_UNMAPPED)  -> (paddr inside {[map_hi + 1 : ADDR_MAX]});
    (addr_kind == ADDR_BOUNDARY)  -> (paddr inside {map_lo, map_hi,
                                                    ro_lo, ro_lo - 1,
                                                    map_hi + 1});

    // Word alignment unless boundary probing or the test opts out
    if (!allow_unaligned && addr_kind != ADDR_BOUNDARY)
      paddr[1:0] == 2'b00;
  }

  constraint c_data {
    solve data_kind before pwdata;
    solve walk_idx  before pwdata;

    data_kind dist { DATA_RANDOM := 40,
                     DATA_WALK_1 := 15,
                     DATA_WALK_0 := 15,
                     DATA_ALT_AA :=  7,
                     DATA_ALT_55 :=  7,
                     DATA_MIN    :=  8,
                     DATA_MAX    :=  8 };

    walk_idx < DATA_WIDTH;

    (data_kind == DATA_WALK_1) -> (pwdata == (data_t'(1) << walk_idx));
    (data_kind == DATA_WALK_0) -> (pwdata == ~(data_t'(1) << walk_idx));
    (data_kind == DATA_ALT_AA) -> (pwdata == {(DATA_WIDTH/2){2'b10}});
    (data_kind == DATA_ALT_55) -> (pwdata == {(DATA_WIDTH/2){2'b01}});
    (data_kind == DATA_MIN)    -> (pwdata == '0);
    (data_kind == DATA_MAX)    -> (pwdata == '1);
  }

  constraint c_strb {
    // PSTRB must not be active during a read transfer
    if (!pwrite) pstrb == '0;
    else pstrb dist { STRB_ALL := 70, [0:STRB_ALL-1] :/ 30 };
  }

  constraint c_timing {
    wait_states dist { 0 := 40, [1:3] :/ 40, [4:MAX_WAIT] :/ 20 };
    idle_cycles dist { 0 := 60, [1:MAX_IDLE] :/ 40 };   // 0 => back-to-back
  }

  // --------------------------------------------------------------------------
  // Constructor
  // --------------------------------------------------------------------------
  function new(string name = "apb_seq_item");
    super.new(name);
  endfunction

  // --------------------------------------------------------------------------
  // Utility methods
  // --------------------------------------------------------------------------
  virtual function void do_copy(uvm_object rhs);
    this_type rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs))
      `uvm_fatal("APB_ITEM", "do_copy: rhs is not an apb_seq_item of the same type")
    paddr                = rhs_.paddr;
    pwrite               = rhs_.pwrite;
    pwdata               = rhs_.pwdata;
    pstrb                = rhs_.pstrb;
    pprot                = rhs_.pprot;
    wait_states          = rhs_.wait_states;
    idle_cycles          = rhs_.idle_cycles;
    addr_kind            = rhs_.addr_kind;
    data_kind            = rhs_.data_kind;
    walk_idx             = rhs_.walk_idx;
    prdata               = rhs_.prdata;
    pslverr              = rhs_.pslverr;
    observed_wait_states = rhs_.observed_wait_states;
    burst_len            = rhs_.burst_len;
    burst_idx            = rhs_.burst_idx;
    allow_unaligned      = rhs_.allow_unaligned;
  endfunction

  // Functional compare for the scoreboard. Timing fields (wait/idle) and
  // metadata are intentionally excluded. PRDATA is only meaningful on an
  // error-free read; PWDATA/PSTRB only on a write.
  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    this_type rhs_;
    bit       ok;
    if (!$cast(rhs_, rhs)) return 0;
    ok  = super.do_compare(rhs, comparer);
    ok &= (paddr   === rhs_.paddr);
    ok &= (pwrite  === rhs_.pwrite);
    ok &= (pprot   === rhs_.pprot);
    ok &= (pslverr === rhs_.pslverr);
    if (pwrite) begin
      ok &= (pwdata === rhs_.pwdata);
      ok &= (pstrb  === rhs_.pstrb);
    end
    else if (!pslverr) begin
      ok &= (prdata === rhs_.prdata);
    end
    return ok;
  endfunction

  virtual function string convert2string();
    return $sformatf("%s addr=0x%0h (%s) %s=0x%0h strb=0x%0h prot=%03b wait=%0d idle=%0d err=%0b burst=%0d/%0d",
                     pwrite ? "WR" : "RD",
                     paddr, addr_kind.name(),
                     pwrite ? "wdata" : "rdata",
                     pwrite ? pwdata : prdata,
                     pstrb, pprot, wait_states, idle_cycles, pslverr,
                     burst_idx, burst_len);
  endfunction

endclass : apb_seq_item
