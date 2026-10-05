// -----------------------------------------------------------------------------
// tb_top.sv : self-contained APB VIP testbench (no DUT)
//
// The master agent drives the master-side signals, the slave agent drives the
// slave-side signals, and the monitor/SVA/coverage observe the same apb_if.
//
// Plusargs:
//   +MID_RESET_AT=<cycle>   pulse reset <cycle> clocks after the initial release
//   +MID_RESET_LEN=<cycles> pulse length (default 3)
// Reset is asserted/released on the FALLING clock edge so it never races the
// rising-edge sampling in the clocking blocks.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_pkg::*;
  import apb_test_pkg::*;

  logic PCLK    = 1'b0;
  logic PRESETn = 1'b0;

  // 100 MHz clock
  always #5 PCLK = ~PCLK;

  apb_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) apb_vif (.PCLK(PCLK), .PRESETn(PRESETn));

  // --------------------------------------------------------------------------
  // Reset generation
  // --------------------------------------------------------------------------
  int unsigned mid_reset_at  = 0;
  int unsigned mid_reset_len = 3;

  initial begin : reset_gen
    PRESETn = 1'b0;
    repeat (5) @(posedge PCLK);
    @(negedge PCLK) PRESETn = 1'b1;

    if ($value$plusargs("MID_RESET_AT=%d", mid_reset_at) && mid_reset_at > 0) begin
      void'($value$plusargs("MID_RESET_LEN=%d", mid_reset_len));
      repeat (mid_reset_at) @(posedge PCLK);
      @(negedge PCLK) PRESETn = 1'b0;
      repeat (mid_reset_len) @(posedge PCLK);
      @(negedge PCLK) PRESETn = 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // UVM start
  // --------------------------------------------------------------------------
  initial begin : uvm_start
    uvm_config_db #(virtual apb_if #(32, 32))::set(null, "uvm_test_top", "vif", apb_vif);
    run_test();
  end

endmodule : tb_top
