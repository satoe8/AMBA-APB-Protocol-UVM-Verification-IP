// -----------------------------------------------------------------------------
// apb_mem_model.sv : slave register-file model (included inside apb_pkg)
//
// Single source of truth for the slave's behavior; the slave driver owns one
// instance and exposes the handle so the scoreboard can use it as the golden
// reference. The address map is shared with apb_seq_item (map_lo/hi, ro_lo/hi).
//
// Rules:
//   - unmapped address                 -> PSLVERR on read AND write, no side effect
//   - write to protected (read-only)   -> PSLVERR, memory unchanged
//   - sparse writes honor PSTRB byte lanes
//   - unwritten words read back default_data
//   - optional: err_on_misaligned flags non-word-aligned accesses
//
// Backdoor: peek()/poke() bypass all rules (use poke() to preload read-only
// registers, peek() for scoreboard comparison).
// -----------------------------------------------------------------------------
class apb_mem_model #(int unsigned ADDR_WIDTH = 32,
                      int unsigned DATA_WIDTH = 32) extends uvm_object;

  localparam int unsigned STRB_W = DATA_WIDTH / 8;

  typedef bit [ADDR_WIDTH-1:0] addr_t;
  typedef bit [DATA_WIDTH-1:0] data_t;
  typedef bit [STRB_W-1:0]     strb_t;
  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;

  `uvm_object_param_utils(apb_mem_model #(ADDR_WIDTH, DATA_WIDTH))

  // Knobs
  data_t default_data      = '0;
  bit    err_on_misaligned = 1'b0;

  // Statistics
  int unsigned num_reads  = 0;
  int unsigned num_writes = 0;
  int unsigned num_errors = 0;

  protected data_t store [addr_t];   // word-aligned address -> data

  function new(string name = "apb_mem_model");
    super.new(name);
  endfunction

  // --------------------------------------------------------------------------
  // Address helpers
  // --------------------------------------------------------------------------
  protected function addr_t word_key(addr_t a);
    return a & ~addr_t'(STRB_W - 1);
  endfunction

  function bit is_mapped(addr_t a);
    return (a >= item_t::map_lo) && (a <= item_t::map_hi);
  endfunction

  function bit is_protected(addr_t a);
    return is_mapped(a) && (a >= item_t::ro_lo) && (a <= item_t::ro_hi);
  endfunction

  function apb_addr_kind_e classify_addr(addr_t a);
    if (is_protected(a)) return ADDR_PROTECTED;
    if (is_mapped(a))    return ADDR_VALID;
    return ADDR_UNMAPPED;
  endfunction

  // Expected PSLVERR for an access (pure function: usable by the scoreboard)
  function bit exp_error(addr_t a, bit write);
    if (!is_mapped(a))                return 1'b1;
    if (write && is_protected(a))     return 1'b1;
    if (err_on_misaligned && ((a & addr_t'(STRB_W - 1)) != '0)) return 1'b1;
    return 1'b0;
  endfunction

  // --------------------------------------------------------------------------
  // Bus-side access (apply rules). Return value: 1 = error response.
  // --------------------------------------------------------------------------
  function bit write(addr_t a, data_t d, strb_t s);
    data_t merged;
    if (exp_error(a, 1'b1)) begin
      num_errors++;
      return 1'b1;
    end
    merged = peek(a);
    for (int i = 0; i < STRB_W; i++)
      if (s[i]) merged[8*i +: 8] = d[8*i +: 8];
    store[word_key(a)] = merged;
    num_writes++;
    return 1'b0;
  endfunction

  function bit read(addr_t a, output data_t d);
    if (exp_error(a, 1'b0)) begin
      d = '0;
      num_errors++;
      return 1'b1;
    end
    d = peek(a);
    num_reads++;
    return 1'b0;
  endfunction

  // --------------------------------------------------------------------------
  // Backdoor access (no rules, no statistics)
  // --------------------------------------------------------------------------
  function data_t peek(addr_t a);
    addr_t k = word_key(a);
    return store.exists(k) ? store[k] : default_data;
  endfunction

  function void poke(addr_t a, data_t d);
    store[word_key(a)] = d;
  endfunction

  function bit is_written(addr_t a);
    return store.exists(word_key(a));
  endfunction

  function void reset();
    store.delete();
  endfunction

endclass : apb_mem_model
