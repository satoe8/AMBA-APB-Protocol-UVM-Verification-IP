// -----------------------------------------------------------------------------
// apb_master_driver.sv : APB master (requester) driver (included inside apb_pkg)
//
// Timing (drives with <= through drv_cb, sampling through drv_cb):
//   edge E     : drive SETUP  (PSEL=1, PENABLE=0, request signals)
//   edge E+1   : drive ACCESS (PENABLE=1)           [request signals untouched]
//   edge E+1+k : PREADY sampled; k = number of wait cycles
//   completion : PREADY==1 sampled -> sample PRDATA/PSLVERR, then at the SAME edge
//                  next item with idle_cycles == 0 -> drive its SETUP (PSEL stays 1)
//                  otherwise                       -> drive idle (PSEL=0, PENABLE=0)
// idle_cycles = N (N>0) inserts exactly N cycles with PSEL low before the SETUP.
//
// Items are cloned and item_done() is called as soon as an item is taken, so the
// sequence can run ahead; an objection is held while work is pending/in flight.
// Reset aborts the transfer in flight (bus returns to idle); the abort is counted.
// A transfer that never sees PREADY within timeout_cycles is reported and aborted.
//
// Published on `ap` at completion: request + observed response + wait count.
// -----------------------------------------------------------------------------
class apb_master_driver #(int unsigned ADDR_WIDTH = 32,
                          int unsigned DATA_WIDTH = 32)
  extends uvm_driver #(apb_seq_item #(ADDR_WIDTH, DATA_WIDTH));

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH)   item_t;
  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef enum {XFER_DONE, XFER_RESET, XFER_TIMEOUT} xfer_res_e;

  `uvm_component_param_utils(apb_master_driver #(ADDR_WIDTH, DATA_WIDTH))

  uvm_analysis_port #(item_t) ap;

  // Knobs
  int unsigned timeout_cycles = 1000;
  bit          send_responses = 1'b0;   // 1: put_response() the completed item to the sequence

  // Statistics
  int unsigned num_xfers    = 0;
  int unsigned num_b2b      = 0;
  int unsigned num_reads    = 0;
  int unsigned num_writes   = 0;
  int unsigned num_err_resp = 0;
  int unsigned num_aborted  = 0;
  int unsigned num_timeouts = 0;

  protected vif_t     vif;
  protected item_t    pending    = null;   // fetched, not yet driven
  protected uvm_phase run_ph;
  protected bit       objected   = 1'b0;
  protected bit       rst_active = 1'b1;   // assume reset until the first edge says otherwise

  // --------------------------------------------------------------------------
  function new(string name = "apb_master_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
      `uvm_fatal("APB_MST_NOVIF",
                 {"Virtual interface not set for ", get_full_name(), ".vif"})
  endfunction

  // --------------------------------------------------------------------------
  // Clock/reset helpers
  // --------------------------------------------------------------------------
  protected task wait_edge(output bit ok);
    @(vif.drv_cb);
    rst_active = (vif.drv_cb.PRESETn !== 1'b1);
    ok         = !rst_active;
  endtask

  protected task raise_obj();
    if (!objected) begin
      run_ph.raise_objection(this, "APB master transfers pending");
      objected = 1'b1;
    end
  endtask

  protected task drop_obj();
    if (objected) begin
      run_ph.drop_objection(this, "APB master idle");
      objected = 1'b0;
    end
  endtask

  // --------------------------------------------------------------------------
  // Pin drives
  // --------------------------------------------------------------------------
  protected task drive_idle();
    vif.drv_cb.PSEL    <= 1'b0;
    vif.drv_cb.PENABLE <= 1'b0;
    vif.drv_cb.PWRITE  <= 1'b0;
    vif.drv_cb.PADDR   <= '0;
    vif.drv_cb.PWDATA  <= '0;
    vif.drv_cb.PSTRB   <= '0;
    vif.drv_cb.PPROT   <= '0;
  endtask

  protected task drive_setup(item_t it);
    vif.drv_cb.PSEL    <= 1'b1;
    vif.drv_cb.PENABLE <= 1'b0;
    vif.drv_cb.PWRITE  <= it.pwrite;
    vif.drv_cb.PADDR   <= it.paddr;
    vif.drv_cb.PWDATA  <= it.pwdata;
    vif.drv_cb.PSTRB   <= it.pwrite ? it.pstrb : '0;   // PSTRB must be low on reads
    vif.drv_cb.PPROT   <= it.pprot;
  endtask

  protected task drive_penable();
    vif.drv_cb.PENABLE <= 1'b1;
  endtask

  // --------------------------------------------------------------------------
  // Sequencer access: items are cloned so sequences may reuse their objects
  // --------------------------------------------------------------------------
  protected task fetch(output item_t it);
    item_t p;
    seq_item_port.get_next_item(p);
    if (!$cast(it, p.clone()))
      `uvm_fatal("APB_MST_CAST", "Clone of sequence item failed")
    it.set_id_info(p);
    raise_obj();                       // BEFORE item_done(): the sequence may finish right after it
    seq_item_port.item_done();
  endtask

  protected task try_fetch(output item_t it);
    item_t p;
    it = null;
    seq_item_port.try_next_item(p);
    if (p != null) begin
      if (!$cast(it, p.clone()))
        `uvm_fatal("APB_MST_CAST", "Clone of sequence item failed")
      it.set_id_info(p);
      raise_obj();                     // no-op if already raised; see fetch()
      seq_item_port.item_done();
    end
  endtask

  // --------------------------------------------------------------------------
  // One transfer, starting at the current clock edge
  // --------------------------------------------------------------------------
  protected task run_transfer(item_t it, output xfer_res_e res);
    int unsigned wait_cnt = 0;
    bit          ok;

    drive_setup(it);                       // SETUP phase
    wait_edge(ok);                         // slave samples SETUP here
    if (!ok) begin res = XFER_RESET; return; end

    drive_penable();                       // ACCESS phase
    if (pending == null) try_fetch(pending);   // look-ahead for the back-to-back decision

    forever begin
      wait_edge(ok);
      if (!ok) begin res = XFER_RESET; return; end
      if (vif.drv_cb.PREADY === 1'b1) break;
      wait_cnt++;
      if (wait_cnt >= timeout_cycles) begin
        `uvm_error("APB_MST_TIMEOUT",
                   $sformatf("PREADY not seen within %0d cycles | %s",
                             timeout_cycles, it.convert2string()))
        res = XFER_TIMEOUT;
        return;
      end
    end

    // Completion edge: sample the response
    it.observed_wait_states = wait_cnt;
    if ($isunknown(vif.drv_cb.PSLVERR))
      `uvm_error("APB_MST_X", "Unknown PSLVERR at transfer completion")
    it.pslverr = vif.drv_cb.PSLVERR;
    if (!it.pwrite) begin
      if (!it.pslverr && $isunknown(vif.drv_cb.PRDATA))
        `uvm_error("APB_MST_X", "Unknown PRDATA on error-free read completion")
      it.prdata = vif.drv_cb.PRDATA;
    end
    res = XFER_DONE;
  endtask

  // --------------------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    item_t     cur;
    xfer_res_e res;
    bit        ok;

    run_ph = phase;
    drive_idle();

    forever begin
      // ---- hold the bus idle until reset is released -------------------------
      while (rst_active) begin
        drive_idle();
        wait_edge(ok);
      end

      // ---- acquire work -------------------------------------------------------
      if (pending == null) begin
        fetch(pending);                // blocks until a sequence supplies an item (raises objection)
        wait_edge(ok);                 // align to a clock edge
        if (!ok) continue;
      end

      // ---- honor the requested idle gap (0 => back-to-back, no extra cycle) ---
      if (pending.idle_cycles > 0) begin
        ok = 1'b1;
        drive_idle();
        repeat (pending.idle_cycles) begin
          wait_edge(ok);
          if (!ok) break;
        end
        if (!ok) continue;
      end

      cur     = pending;
      pending = null;
      run_transfer(cur, res);          // may fetch the next item (look-ahead)

      case (res)
        XFER_DONE: begin
          num_xfers++;
          if (cur.pwrite) num_writes++; else num_reads++;
          if (cur.pslverr) num_err_resp++;
          `uvm_info("APB_MST", cur.convert2string(), UVM_HIGH)
          ap.write(cur);
          if (send_responses) seq_item_port.put_response(cur);
          if (pending == null) begin
            drive_idle();              // PSEL/PENABLE low from the next cycle
            drop_obj();
          end
          else if (pending.idle_cycles == 0) begin
            num_b2b++;                 // next SETUP is driven at this same edge
          end
        end

        XFER_RESET: begin
          num_aborted++;
          `uvm_warning("APB_MST_RST", "Transfer in flight aborted by reset")
          drive_idle();
          if (pending == null) drop_obj();
        end

        XFER_TIMEOUT: begin
          num_timeouts++;
          drive_idle();
          if (pending == null) drop_obj();
        end
      endcase
    end
  endtask

  // --------------------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("APB_MST",
              $sformatf("Completed %0d transfers (%0d rd / %0d wr, %0d error resp, %0d back-to-back), %0d aborted, %0d timeouts",
                        num_xfers, num_reads, num_writes, num_err_resp,
                        num_b2b, num_aborted, num_timeouts),
              UVM_LOW)
  endfunction

endclass : apb_master_driver
