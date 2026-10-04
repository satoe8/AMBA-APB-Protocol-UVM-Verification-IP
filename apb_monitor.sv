// -----------------------------------------------------------------------------
// apb_monitor.sv : passive APB monitor (included inside apb_pkg)
//
// One item is published on `ap` per COMPLETED transfer (PSEL && PENABLE && PREADY).
// Item contents:
//   request : paddr, pwrite, pwdata (writes), pstrb, pprot   (sampled in SETUP)
//   response: prdata (reads), pslverr                         (sampled at completion)
//   timing  : observed_wait_states / wait_states = PREADY-low cycles in ACCESS
//             idle_cycles = cycles with PSEL low since the previous transfer
//             (0 => back-to-back; includes post-reset idle for the first transfer)
//   addr_kind is DERIVED from the address map (valid / protected / unmapped).
//   data_kind / walk_idx are NOT recoverable from the bus: coverage must
//   classify data from the pwdata value itself.
//
// vif is fetched from uvm_config_db under the key "vif".
// -----------------------------------------------------------------------------
class apb_monitor #(int unsigned ADDR_WIDTH = 32,
                    int unsigned DATA_WIDTH = 32) extends uvm_monitor;

  typedef apb_seq_item #(ADDR_WIDTH, DATA_WIDTH) item_t;
  typedef virtual apb_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;

  `uvm_component_param_utils(apb_monitor #(ADDR_WIDTH, DATA_WIDTH))

  // Broadcast of completed transfers (scoreboard, coverage, ...)
  uvm_analysis_port #(item_t) ap;

  protected vif_t vif;

  // Statistics (reported in report_phase)
  int unsigned num_xfers    = 0;
  int unsigned num_aborted  = 0;  // dropped by reset or protocol violation
  int unsigned num_proto_err = 0; // violations seen by the monitor

  // --------------------------------------------------------------------------
  function new(string name = "apb_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // --------------------------------------------------------------------------
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(vif_t)::get(this, "", "vif", vif))
      `uvm_fatal("APB_MON_NOVIF",
                 {"Virtual interface not set for ", get_full_name(), ".vif"})
  endfunction

  // --------------------------------------------------------------------------
  // Address classification from the shared address map
  // --------------------------------------------------------------------------
  protected function apb_addr_kind_e classify_addr(bit [ADDR_WIDTH-1:0] a);
    if (a >= item_t::ro_lo  && a <= item_t::ro_hi)  return ADDR_PROTECTED;
    if (a >= item_t::map_lo && a <= item_t::map_hi) return ADDR_VALID;
    return ADDR_UNMAPPED;
  endfunction

  // --------------------------------------------------------------------------
  // Capture the request phase (call in a cycle where PSEL == 1)
  // --------------------------------------------------------------------------
  protected function item_t sample_request(int unsigned idle);
    item_t t;
    t = item_t::type_id::create("apb_mon_item");

    if ($isunknown({vif.mon_cb.PADDR, vif.mon_cb.PWRITE,
                    vif.mon_cb.PPROT, vif.mon_cb.PSTRB})) begin
      num_proto_err++;
      `uvm_error("APB_MON_X", "Unknown value on PADDR/PWRITE/PPROT/PSTRB while PSEL high")
    end

    t.paddr       = vif.mon_cb.PADDR;
    t.pwrite      = vif.mon_cb.PWRITE;
    t.pstrb       = vif.mon_cb.PSTRB;
    t.pprot       = vif.mon_cb.PPROT;
    t.idle_cycles = idle;
    t.addr_kind   = classify_addr(vif.mon_cb.PADDR);

    if (t.pwrite) begin
      if ($isunknown(vif.mon_cb.PWDATA)) begin
        num_proto_err++;
        `uvm_error("APB_MON_X", "Unknown value on PWDATA during write")
      end
      t.pwdata = vif.mon_cb.PWDATA;
    end
    return t;
  endfunction

  // --------------------------------------------------------------------------
  // Main loop: one iteration per PCLK edge, sampled through mon_cb (#1step)
  // --------------------------------------------------------------------------
  virtual task run_phase(uvm_phase phase);
    item_t       item     = null;
    bit          in_xfer  = 1'b0;
    int unsigned wait_cnt = 0;
    int unsigned idle_cnt = 0;

    forever begin
      @(vif.mon_cb);

      // ---------------- Reset: discard anything in flight -------------------
      if (vif.mon_cb.PRESETn !== 1'b1) begin
        if (in_xfer) begin
          num_aborted++;
          `uvm_warning("APB_MON_RST", "Transfer in flight discarded by reset")
        end
        item     = null;
        in_xfer  = 1'b0;
        wait_cnt = 0;
        idle_cnt = 0;
        continue;
      end

      // ---------------- Bus idle (PSEL low) ---------------------------------
      if (vif.mon_cb.PSEL !== 1'b1) begin
        if (in_xfer) begin
          num_aborted++;
          num_proto_err++;
          `uvm_error("APB_MON_PROTO", "PSEL dropped before transfer completed")
          item    = null;
          in_xfer = 1'b0;
        end
        idle_cnt++;
        continue;
      end

      // ---------------- PSEL high: SETUP or ACCESS --------------------------
      case (vif.mon_cb.PENABLE)

        1'b0: begin // SETUP
          if (in_xfer) begin
            num_aborted++;
            num_proto_err++;
            `uvm_error("APB_MON_PROTO", "New SETUP before previous transfer completed")
          end
          item     = sample_request(idle_cnt);
          in_xfer  = 1'b1;
          wait_cnt = 0;
          idle_cnt = 0;
        end

        1'b1: begin // ACCESS
          if (!in_xfer) begin
            num_proto_err++;
            `uvm_error("APB_MON_PROTO", "ACCESS phase without preceding SETUP")
            item     = sample_request(idle_cnt);
            in_xfer  = 1'b1;
            wait_cnt = 0;
            idle_cnt = 0;
          end

          case (vif.mon_cb.PREADY)
            1'b1: begin // transfer completes in this cycle
              item.observed_wait_states = wait_cnt;
              item.wait_states          = wait_cnt;
              if ($isunknown(vif.mon_cb.PSLVERR)) begin
                num_proto_err++;
                `uvm_error("APB_MON_X", "Unknown PSLVERR at transfer completion")
              end
              item.pslverr = vif.mon_cb.PSLVERR;
              if (!item.pwrite) begin
                if (!item.pslverr && $isunknown(vif.mon_cb.PRDATA)) begin
                  num_proto_err++;
                  `uvm_error("APB_MON_X", "Unknown PRDATA on error-free read completion")
                end
                item.prdata = vif.mon_cb.PRDATA;
              end
              num_xfers++;
              `uvm_info("APB_MON", item.convert2string(), UVM_HIGH)
              ap.write(item);
              item    = null;
              in_xfer = 1'b0;
            end

            1'b0: wait_cnt++; // wait state: PREADY low in ACCESS

            default: begin    // PREADY unknown: count as wait, flag it
              num_proto_err++;
              `uvm_error("APB_MON_X", "Unknown PREADY during ACCESS")
              wait_cnt++;
            end
          endcase
        end

        default: begin // PENABLE unknown
          num_proto_err++;
          `uvm_error("APB_MON_X", "Unknown PENABLE while PSEL high")
        end

      endcase
    end
  endtask

  // --------------------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("APB_MON",
              $sformatf("Observed %0d transfers, %0d aborted, %0d monitor-detected violations",
                        num_xfers, num_aborted, num_proto_err),
              UVM_LOW)
  endfunction

endclass : apb_monitor
