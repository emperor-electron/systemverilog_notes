// -----------------------------------------------------------------------------
// axil_slave.sv -- AXI4-Lite subordinate, translating the bus into the same
// generic register port apb_slave.sv produces (see csr_bank.sv).
//
// AXI4-Lite has five INDEPENDENT channels, and independent is the whole
// difficulty. Everything below follows from three rules:
//
//   1. AW and W ARRIVE IN EITHER ORDER, and with any gap. A manager may send
//      the write data first, or the address first, or both together, and
//      nothing in the specification lets a subordinate require one order. A
//      subordinate that waits for AW before accepting W deadlocks against a
//      manager that waits to send AW until W is accepted. Here each channel is
//      accepted into its own holding register the moment it arrives, and the
//      write happens when both are present.
//
//   2. VALID MUST NOT WAIT FOR READY. A manager may not delay AWVALID until it
//      sees AWREADY; likewise a subordinate may not delay BVALID until BREADY.
//      READY may depend on VALID, never the other way round. Every *ready here
//      is a function of registers only, so the rule holds structurally rather
//      than by inspection.
//
//   3. ONCE VALID IS ASSERTED IT STAYS ASSERTED, with its payload unchanged,
//      until the handshake completes. That is the caller's obligation, and it
//      is asserted below so a misbehaving manager is caught here rather than
//      three modules downstream.
//
// B RESPONSE ORDERING: exactly one B per write, and none before both AW and W
// have been accepted. Issuing B early is a surprisingly common bug and it looks
// fine until the manager counts outstanding writes.
//
//
// ADDRESSING: the address is passed through to the register port unmodified.
// Whether it is a byte address or a register index is the integrator's choice;
// a byte-addressed system drops the low $clog2(DW/8) bits on the way in. Doing
// that here would bake an assumption into the module that half its users do not
// share.
// This subordinate is single-outstanding -- it accepts one write and one read
// at a time. That is a normal and legal choice for a register block; the cost
// is throughput, not correctness.
// -----------------------------------------------------------------------------
`default_nettype none

module axil_slave #(
  parameter int unsigned AW = 8,
  parameter int unsigned DW = 32
) (
  input  var logic            clk,
  input  var logic            rst_n,

  // Write address channel
  input  var logic [AW-1:0]   awaddr,
  input  var logic            awvalid,
  output var logic            awready,
  // Write data channel
  input  var logic [DW-1:0]   wdata,
  input  var logic [DW/8-1:0] wstrb,
  input  var logic            wvalid,
  output var logic            wready,
  // Write response channel
  output var logic [1:0]      bresp,
  output var logic            bvalid,
  input  var logic            bready,
  // Read address channel
  input  var logic [AW-1:0]   araddr,
  input  var logic            arvalid,
  output var logic            arready,
  // Read data channel
  output var logic [DW-1:0]   rdata,
  output var logic [1:0]      rresp,
  output var logic            rvalid,
  input  var logic            rready,

  // Generic register port
  output var logic [AW-1:0]   reg_addr,
  output var logic            reg_wen,
  output var logic [DW-1:0]   reg_wdata,
  output var logic [DW/8-1:0] reg_wstrb,
  output var logic            reg_ren,
  input  var logic [DW-1:0]   reg_rdata,
  input  var logic            reg_err
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  logic [AW-1:0]   aw_addr_r;
  logic            aw_full;
  logic [DW-1:0]   w_data_r;
  logic [DW/8-1:0] w_strb_r;
  logic            w_full;
  logic [AW-1:0]   ar_addr_r;
  logic            ar_full;

  logic do_write, do_read;

  // Rule 2: every ready is a function of registers alone.
  assign awready = !aw_full;
  assign wready  = !w_full;
  assign arready = !ar_full;

  // Rule 1: the write fires once BOTH halves are in, in whichever order they
  // arrived, and only when the response channel is free to take the answer.
  assign do_write = aw_full && w_full && (!bvalid || bready);
  // Writes take the register port when both want it; the read just waits.
  assign do_read  = ar_full && !do_write && (!rvalid || rready);

  assign reg_addr  = do_write ? aw_addr_r : ar_addr_r;
  assign reg_wdata = w_data_r;
  assign reg_wstrb = w_strb_r;
  assign reg_wen   = do_write;
  assign reg_ren   = do_read;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_addr_r <= '0;  aw_full <= 1'b0;
      w_data_r  <= '0;  w_strb_r <= '0;  w_full <= 1'b0;
      ar_addr_r <= '0;  ar_full <= 1'b0;
      bresp     <= RESP_OKAY;  bvalid <= 1'b0;
      rdata     <= '0;  rresp <= RESP_OKAY;  rvalid <= 1'b0;
    end else begin
      // Accept each channel independently, as soon as it offers.
      if (awvalid && awready) begin
        aw_addr_r <= awaddr;
        aw_full   <= 1'b1;
      end
      if (wvalid && wready) begin
        w_data_r <= wdata;
        w_strb_r <= wstrb;
        w_full   <= 1'b1;
      end
      if (arvalid && arready) begin
        ar_addr_r <= araddr;
        ar_full   <= 1'b1;
      end

      // Retire the response handshakes.
      if (bvalid && bready) bvalid <= 1'b0;
      if (rvalid && rready) rvalid <= 1'b0;

      if (do_write) begin
        aw_full <= 1'b0;
        w_full  <= 1'b0;
        bresp   <= reg_err ? RESP_SLVERR : RESP_OKAY;
        bvalid  <= 1'b1;
      end

      if (do_read) begin
        ar_full <= 1'b0;
        rdata   <= reg_rdata;          // combinational read from the bank
        rresp   <= reg_err ? RESP_SLVERR : RESP_OKAY;
        rvalid  <= 1'b1;
      end
    end
  end

`ifdef FORMAL
  // `aw_full` and `w_full` are internal, and a hierarchical reference from a
  // harness reads the wrong net under the Yosys frontend (docs/25).
  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;

  // A write response is only ever produced by an actual write.
  always @(posedge clk)
    if (f_past && rst_n && $past(rst_n) && bvalid && !$past(bvalid))
      f_b_needs_both : assert ($past(aw_full) && $past(w_full));

  // Single outstanding: a second address cannot be accepted while one is held.
  always @* begin
    f_aw_once : assert (!(aw_full && awready));
    f_w_once  : assert (!(w_full  && wready));
    f_ar_once : assert (!(ar_full && arready));
  end

  // ---- transfer accounting -------------------------------------------------
  // The counters live HERE rather than in the harness, and that is the whole
  // reason induction closes. The property that makes "a response is never
  // invented or duplicated" inductive is an exact accounting identity between
  // the counters and this module's internal state:
  //
  //     accepted - responded  ==  still held  +  response outstanding
  //
  // Stated in a harness, the counters are registers the solver may start at any
  // value, unrelated to aw_full/w_full, so the step case fails on states that
  // cannot occur. Stated here, next to the state they account for, each identity
  // is preserved by every transition and induction goes through in one step.
  logic [5:0] f_n_aw, f_n_w, f_n_b, f_n_ar, f_n_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_n_aw <= '0; f_n_w <= '0; f_n_b <= '0; f_n_ar <= '0; f_n_r <= '0;
    end else begin
      if (awvalid && awready) f_n_aw <= f_n_aw + 1'b1;
      if (wvalid  && wready)  f_n_w  <= f_n_w  + 1'b1;
      if (bvalid  && bready)  f_n_b  <= f_n_b  + 1'b1;
      if (arvalid && arready) f_n_ar <= f_n_ar + 1'b1;
      if (rvalid  && rready)  f_n_r  <= f_n_r  + 1'b1;
    end
  end

  always @* begin
    f_aw_acct : assert ((f_n_aw - f_n_b) == (6'(aw_full) + 6'(bvalid)));
    f_w_acct  : assert ((f_n_w  - f_n_b) == (6'(w_full)  + 6'(bvalid)));
    f_ar_acct : assert ((f_n_ar - f_n_r) == (6'(ar_full) + 6'(rvalid)));

    // What the accounting buys, stated wrap-safely.
    //
    // NOT `f_n_b <= f_n_aw`. These counters are free-running and wrap, so that
    // comparison is simply false for reachable states -- n_aw = 1 with n_b = 63
    // is a perfectly ordinary wrapped state and induction rightly rejects the
    // claim. The MODULAR DIFFERENCE is the quantity that means something, and
    // bounding it says both of the things the naive comparison was reaching
    // for: a response never appears without a request (which would make the
    // difference wrap to a huge number) and none is ever duplicated.
    f_b_bounded : assert ((f_n_aw - f_n_b) <= 6'd2);
    f_w_bounded : assert ((f_n_w  - f_n_b) <= 6'd2);
    f_r_bounded : assert ((f_n_ar - f_n_r) <= 6'd2);
  end
`endif

`ifndef SYNTHESIS
  // Rule 3, checked against the manager: valid is sticky and its payload frozen.
  a_awvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (awvalid && !awready) |=> (awvalid && $stable(awaddr)))
    else $error("axil_slave: AWVALID or AWADDR moved before AWREADY");

  a_wvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb)))
    else $error("axil_slave: WVALID or WDATA moved before WREADY");

  a_arvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (arvalid && !arready) |=> (arvalid && $stable(araddr)))
    else $error("axil_slave: ARVALID or ARADDR moved before ARREADY");

  // ...and the same obligation on this module's own outputs.
  a_bvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (bvalid && !bready) |=> (bvalid && $stable(bresp)));

  a_rvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (rvalid && !rready) |=> (rvalid && $stable(rdata) && $stable(rresp)));

  // No response before both halves of the write have been accepted.
  a_b_needs_both: assert property (@(posedge clk) disable iff (!rst_n)
    (bvalid && !$past(bvalid)) |-> $past(aw_full && w_full))
    else $error("axil_slave: BVALID before both AW and W were accepted");

  a_wen_with_write: assert property (@(posedge clk) disable iff (!rst_n)
    reg_wen |-> (aw_full && w_full));
`endif

endmodule

`default_nettype wire
