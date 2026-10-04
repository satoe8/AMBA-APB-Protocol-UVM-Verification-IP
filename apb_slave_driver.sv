// -----------------------------------------------------------------------------
// apb_slave_driver.sv : APB slave (completer) responder (included inside apb_pkg)
//
// Timing model (all sampling through slv_cb, drives with <= through slv_cb):
//   edge N   : SETUP sampled (PSEL=1, PENABLE=0)
//                wait_states == 0 -> present response, PREADY=1 for the ACCESS cycle
//                wait_states == N -> PREADY=0
//   edge N+k : ACCESS sampled with PREADY=0 -> wait cycle; after the Nth wait
//              cycle the response is presented with PREADY=1
//   edge N+m : ACCESS sampled with PREADY=1 -> transfer complete, publish on
//              resp_ap, return to not-ready/idle
// Write data is committed to the memory model when PREADY=1 is presented,
// i.e. one cycle BEFORE the monitor publishes the same transfer. A scoreboard
// reading the memory when the monitor item arrives therefore sees the
// post-write state with no race.
//
// Wait counts come from a plan queue fed by a background thread pulling items
// from the sequencer (only item.wait_states is used). With no plan available
// the driver falls back to default_wait, so the bus never hangs.
//
// Config (uvm_config_db, set on or above this component):
//   "vif" : virtual apb_if #(ADDR_WIDTH, DATA_WIDTH)   (required)
//   "mem" : apb_mem_model  #(ADDR_WIDTH, DATA_WIDTH)   (optional, shared model)
// -----------------------------------------------------------------------------
class apb_slave_driver #(int unsigned ADDR_WIDTH = 32,
                         int unsigned DATA_WIDTH = 32)
  extends uvm_driver #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH)   item_t;
  typedef apb_mem_model #(ADDR_WIDTH, DATA_WIDTH)  mem_t;
  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef bit [DATA_WIDTH-1:0]                     data_t;

  `uvm_component_param_utils(apb_slave_driver #(ADDR_WIDTH, DATA_WIDTH))

  // Shared golden-model handle and response broadcast
  mem_t                       mem;
  uvm_analysis_port #(item_t) resp_ap;

  // Knobs (set before the run phase)
  int unsigned default_wait            = 0;     // used when no plan item is available
  int unsigned plan_depth              = 2;     // prefetch depth from the sequencer
  bit          randomize_rdata_in_wait = 1'b1;  // junk PRDATA while PREADY low
  bit          clear_mem_on_reset      = 1'b1;

  // Statistics
  int unsigned num_xfers         = 0;
  int unsigned num_err_resp      = 0;
  int unsigned num_aborted       = 0;
  int unsigned num_default_plans = 0;

  protected vif_t       vif;
  protected item_t      plan_q[$];
  protected semaphore   plan_slots;
  protected item_t      cur         = null;
  protected bit         busy        = 1'b0;
  protected bit         ready_drv   = 1'b0;   // PREADY currently presented high
  protected bit         req_unknown = 1'b0;
  protected int unsigned remaining  = 0;      // wait cycles still to sample

  // --------------------------------------------------------------------------
  function new(string name = "apb_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function mem_t get_mem();
    return mem;
  endfunction

  // --------------------------------------------------------------------------
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    resp_ap = new("resp_ap", this);
    if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
      `uvm_fatal("APB_SLV_NOVIF",
                 {"Virtual interface not set for ", get_full_name(), ".vif"})
    if (!uvm_config_db #(mem_t)::get(this, "", "mem", mem))
      mem = mem_t::type_id::create("mem");
  endfunction

  // --------------------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    plan_slots = new(plan_depth);
    fork
      fetch_plans();
      respond();
    join
  endtask

  // --------------------------------------------------------------------------
  // Plan prefetch: only wait_states is consumed; items are cloned so sequences
  // may safely reuse their item objects.
  // --------------------------------------------------------------------------
  protected task fetch_plans();
    item_t p, c;
    forever begin
      plan_slots.get(1);
      seq_item_port.get_next_item(p);
      if (!$cast(c, p.clone()))
        `uvm_fatal("APB_SLV_CAST", "Clone of plan item failed")
      plan_q.push_back(c);
      seq_item_port.item_done();
    end
  endtask

  protected task next_wait(output int unsigned w);
    item_t p;
    if (plan_q.size() > 0) begin
      p = plan_q.pop_front();
      plan_slots.put(1);
      w = p.wait_states;
    end
    else begin
      num_default_plans++;
      w = default_wait;
    end
  endtask

  // --------------------------------------------------------------------------
  // Pin drives (clocking-block drives are non-blocking by definition)
  // --------------------------------------------------------------------------
  protected task drive_not_ready();
    data_t junk = '0;
    if (randomize_rdata_in_wait) void'(std::randomize(junk));
    vif.slv_cb.PREADY  <= 1'b0;
    vif.slv_cb.PSLVERR <= 1'b0;
    vif.slv_cb.PRDATA  <= junk;
  endtask

  protected function void compute_response();
    bit    err;
    data_t rd;
    rd = '0;
    if (req_unknown)    err = 1'b1;
    else if (cur.pwrite) err = mem.write(cur.paddr, cur.pwdata, cur.pstrb);
    else                 err = mem.read(cur.paddr, rd);
    cur.pslverr = err;
    cur.prdata  = rd;
  endfunction

  protected task present_ready();
    compute_response();   // commits writes to the memory model
    ready_drv = 1'b1;
    vif.slv_cb.PREADY  <= 1'b1;
    vif.slv_cb.PSLVERR <= cur.pslverr;
    vif.slv_cb.PRDATA  <= cur.prdata;
  endtask

  // --------------------------------------------------------------------------
  // Transfer start (SETUP sampled)
  // --------------------------------------------------------------------------
  protected task start_transfer();
    int unsigned w;
    cur = item_t::type_id::create("apb_slv_item");

    req_unknown = $isunknown({vif.slv_cb.PADDR, vif.slv_cb.PWRITE,
                              vif.slv_cb.PPROT, vif.slv_cb.PSTRB});
    if (req_unknown)
      `uvm_error("APB_SLV_X", "Unknown value on request signals in SETUP; responding with PSLVERR")

    cur.paddr  = vif.slv_cb.PADDR;
    cur.pwrite = vif.slv_cb.PWRITE;
    cur.pstrb  = vif.slv_cb.PSTRB;
    cur.pprot  = vif.slv_cb.PPROT;
    if (cur.pwrite) begin
      if ($isunknown(vif.slv_cb.PWDATA)) begin
        req_unknown = 1'b1;
        `uvm_error("APB_SLV_X", "Unknown PWDATA during write; responding with PSLVERR")
      end
      cur.pwdata = vif.slv_cb.PWDATA;
    end
    cur.addr_kind = mem.classify_addr(cur.paddr);

    next_wait(w);
    cur.wait_states          = w;
    cur.observed_wait_states = w;

    busy      = 1'b1;
    ready_drv = 1'b0;
    remaining = w;
    if (w == 0) present_ready();
    else        drive_not_ready();
  endtask

  // --------------------------------------------------------------------------
  // Transfer end (ACCESS sampled with our PREADY=1)
  // --------------------------------------------------------------------------
  protected task finish_transfer();
    num_xfers++;
    if (cur.pslverr) num_err_resp++;
    `uvm_info("APB_SLV", cur.convert2string(), UVM_HIGH)
    resp_ap.write(cur);
    busy      = 1'b0;
    ready_drv = 1'b0;
    cur       = null;
    drive_not_ready();
  endtask

  protected task abort_transfer(string why);
    num_aborted++;
    `uvm_warning("APB_SLV_ABORT", why)
    busy      = 1'b0;
    ready_drv = 1'b0;
    remaining = 0;
    cur       = null;
  endtask

  // --------------------------------------------------------------------------
  // Main responder loop: one iteration per PCLK edge
  // --------------------------------------------------------------------------
  protected task respond();
    drive_not_ready();
    forever begin
      @(vif.slv_cb);

      // ---------------- Reset ------------------------------------------------
      if (vif.slv_cb.PRESETn !== 1'b1) begin
        if (busy) abort_transfer("Transfer in flight discarded by reset");
        if (clear_mem_on_reset) mem.reset();
        drive_not_ready();
        continue;
      end

      // ---------------- SETUP -------------------------------------------------
      if (vif.slv_cb.PSEL === 1'b1 && vif.slv_cb.PENABLE === 1'b0) begin
        if (busy) abort_transfer("New SETUP before previous transfer completed");
        start_transfer();
      end

      // ---------------- ACCESS ------------------------------------------------
      else if (vif.slv_cb.PSEL === 1'b1 && vif.slv_cb.PENABLE === 1'b1 && busy) begin
        if (ready_drv) begin
          finish_transfer();               // PREADY=1 was sampled: transfer done
        end
        else begin
          remaining--;                     // one more PREADY-low cycle sampled
          if (remaining == 0) present_ready();
          else                drive_not_ready();
        end
      end

      // ---------------- Idle / illegal ---------------------------------------
      else begin
        if (busy) abort_transfer("PSEL dropped or PENABLE invalid before transfer completed");
        drive_not_ready();
      end
    end
  endtask

  // --------------------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("APB_SLV",
              $sformatf("Completed %0d transfers (%0d error responses), %0d aborted, %0d default plans; mem: %0d rd / %0d wr / %0d err",
                        num_xfers, num_err_resp, num_aborted, num_default_plans,
                        mem.num_reads, mem.num_writes, mem.num_errors),
              UVM_LOW)
  endfunction

endclass : apb_slave_driver
