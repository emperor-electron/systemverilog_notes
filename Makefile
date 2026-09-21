# =============================================================================
# SystemVerilog notes -- lint, simulation and formal verification.
#
#   make            # lint, then simulate, then prove
#   make lint       # xvlog analysis + yosys structural checks
#   make sim        # all testbenches under XSIM
#   make formal     # all proofs under SymbiYosys
#   make <name>     # one simulation target (see SIM_TESTS)
#   make clean
#
# TOOLCHAIN
#   Simulation : XSIM (Vivado Simulator).  4-state, full SVA, `shortreal`,
#                clocking blocks -- everything this repository needs from a
#                simulator, in one tool.
#   Formal     : SymbiYosys (sby) with Yosys and the boolector/z3/yices solvers.
#
# XSIM FLOW
#   xvlog -sv <files>          analyse into the `work` library
#   xelab  <top> -s <snapshot> elaborate
#   xsim   <snapshot> -R       run to completion
#   There is no library-search switch equivalent to -y, so every source file is
#   analysed explicitly and packages must come first.
#
# SBY FLOW
#   Each formal/<module>_fv.sby declares tasks (bmc / prove / cover) and the
#   files to read. `sby -f <file> <task>` runs one; formal/run_all.sh runs all.
#
# WHAT YOSYS CANNOT READ
#   Yosys's open-source SystemVerilog frontend is a subset. It rejects `return`
#   in a function, a local variable with an initialiser inside a function,
#   `foreach`, `string` parameters, unpacked array PORTS, `$bits()` of a type,
#   named assignment patterns, and ALL of SVA's temporal layer (`assert
#   property` with a clocking event, `|->`, `|=>`, sequences, `default
#   clocking`). Ten of the fifty modules here are therefore outside the formal
#   flow; they are still linted and simulated. See docs/25 for the full list and
#   the workarounds.
# =============================================================================

# Vivado's settings script is bash-specific, so make must not use /bin/sh.
SHELL           := /bin/bash

VIVADO_SETTINGS ?= /tools/Xilinx/Vivado/2023.2/settings64.sh
SBY             ?= sby
YOSYS           ?= yosys

RTL_DIR   = examples/rtl
ARITH_DIR = examples/arith
TB_DIR    = examples/tb
FV_DIR    = formal
BUILD     = build

# Packages must be analysed before anything that imports them.
PKGS       = $(ARITH_DIR)/fp_pkg.sv $(ARITH_DIR)/fixed_pkg.sv
RTL_SRCS   = $(wildcard $(RTL_DIR)/*.sv)
ARITH_SRCS = $(filter-out $(PKGS),$(wildcard $(ARITH_DIR)/*.sv))
ALL_SRCS   = $(PKGS) $(RTL_SRCS) $(ARITH_SRCS)

# Two of the "testbenches" are standalone language demos in examples/arith;
# the rest are in examples/tb. The mapping is resolved in the run rule.
SIM_TESTS = signedness width_rules fp arith fifo async_fifo skid smoke \
            pipeline techniques fsm periph serial

TOP_signedness  = signedness_demo
TOP_width_rules = width_rules_tb
TOP_fp          = fp_tb
TOP_arith       = arith_tb
TOP_fifo        = fifo_tb
TOP_async_fifo  = async_fifo_tb
TOP_skid        = skid_buffer_tb
TOP_smoke       = rtl_smoke_tb
TOP_pipeline    = pipeline_tb
TOP_techniques  = techniques_tb
TOP_fsm         = fsm_tb
TOP_periph      = periph_tb
TOP_serial      = serial_tb

# The two demos need no extra file beyond ALL_SRCS; the others add their TB.
EXTRA_signedness  =
EXTRA_width_rules =
EXTRA_fp          = $(TB_DIR)/fp_tb.sv
EXTRA_arith       = $(TB_DIR)/arith_tb.sv
EXTRA_fifo        = $(TB_DIR)/fifo_tb.sv
EXTRA_async_fifo  = $(TB_DIR)/async_fifo_tb.sv
EXTRA_skid        = $(TB_DIR)/skid_buffer_tb.sv
EXTRA_smoke       = $(TB_DIR)/rtl_smoke_tb.sv
EXTRA_pipeline    = $(TB_DIR)/pipeline_tb.sv
EXTRA_techniques  = $(TB_DIR)/techniques_tb.sv
EXTRA_fsm         = $(TB_DIR)/fsm_tb.sv
EXTRA_periph      = $(TB_DIR)/periph_tb.sv
EXTRA_serial      = $(TB_DIR)/serial_tb.sv

.PHONY: all lint sim formal clean $(SIM_TESTS)

all: lint sim formal
	@echo ""
	@echo "=== lint clean, all simulations passed, all proofs passed ==="

# -----------------------------------------------------------------------------
# Lint: xvlog for analysis errors, yosys for inferred latches.
#
# xvlog catches syntax errors, undeclared identifiers (which `default_nettype
# none` turns every typo into) and elaboration problems. It does NOT report
# width truncation or inferred latches, so yosys -- which ships with sby --
# supplies the structural check. Neither tool reports width mismatches; that
# gap is stated in docs/20 rather than papered over.
# -----------------------------------------------------------------------------
lint:
	@mkdir -p $(BUILD)/lint
	@set -e; source $(VIVADO_SETTINGS) >/dev/null 2>&1; cd $(BUILD)/lint; \
	  out=$$(xvlog -sv --nolog $(addprefix ../../,$(ALL_SRCS)) \
	                          $(addprefix ../../,$(wildcard $(TB_DIR)/*.sv)) 2>&1); \
	  if echo "$$out" | grep -q ERROR; then \
	    echo "=== xvlog ==="; echo "$$out" | grep ERROR | head -20; exit 1; \
	  fi; \
	  echo "xvlog: clean"
	@n=0; s=0; f=0; \
	for src in $(RTL_SRCS) $(ARITH_SRCS); do \
	  m=$$(basename $$src .sv); \
	  case $$m in signedness_demo|width_rules_tb) continue;; esac; \
	  o=$$($(YOSYS) -p "read_verilog -sv -DSYNTHESIS $$src; hierarchy -top $$m; proc" 2>&1); \
	  if echo "$$o" | grep -q "ERROR: Latch inferred"; then \
	    echo "=== inferred latch in $$m ==="; \
	    echo "$$o" | grep "ERROR: Latch inferred" | head -3; f=1; \
	  elif echo "$$o" | grep -q "ERROR:"; then s=$$((s+1)); \
	  else n=$$((n+1)); fi; \
	done; \
	echo "yosys: $$n modules latch-checked, $$s outside the frontend subset"; \
	if [ $$f -ne 0 ]; then echo "LINT FAILED"; exit 1; fi; \
	echo "LINT CLEAN"

# -----------------------------------------------------------------------------
# Simulation (XSIM)
#
# A testbench passes only if it prints PASS *and* no SVA assertion failed. Those
# are genuinely separate conditions: a concurrent assertion that fails calls
# $error, which XSIM reports and carries on from, so a testbench whose own
# checks all pass will still print PASS with failing assertions scrolling past
# above it. Grepping for the PASS line alone hides exactly the failures the
# assertions were written to catch.
# -----------------------------------------------------------------------------
sim: $(SIM_TESTS)
	@echo ""
	@echo "=== all $(words $(SIM_TESTS)) simulations passed ==="

$(SIM_TESTS):
	@echo "=== $(TOP_$@) (XSIM) ==="
	@mkdir -p $(BUILD)/$@
	@set -e; source $(VIVADO_SETTINGS) >/dev/null 2>&1; cd $(BUILD)/$@; \
	  xvlog -sv --nolog $(addprefix ../../,$(ALL_SRCS)) \
	                    $(addprefix ../../,$(EXTRA_$@)) > vlog.log 2>&1 \
	    || { echo "ANALYSIS FAILED"; grep -i error vlog.log | head -10; exit 1; }; \
	  xelab -debug typical --nolog -relax $(TOP_$@) -s sim > elab.log 2>&1 \
	    || { echo "ELABORATION FAILED"; grep -i error elab.log | head -10; exit 1; }; \
	  out=$$(xsim sim -R --nolog 2>&1); \
	  echo "$$out" | grep -E "^\[|: (PASS|FAIL)|MISMATCH|FAIL " || true; \
	  echo "$$out" | grep -q ": PASS" \
	    || { echo "*** $(TOP_$@) DID NOT PASS ***"; exit 1; }; \
	  if echo "$$out" | grep -qE "^Error:"; then \
	    echo "*** $(TOP_$@) printed PASS but SVA assertions FAILED ***"; \
	    echo "$$out" | grep -E "^Error:" | sort | uniq -c | head -10; exit 1; \
	  fi

# -----------------------------------------------------------------------------
# Formal (SymbiYosys)
# -----------------------------------------------------------------------------
formal:
	@echo "=== formal proofs (SymbiYosys) ==="
	@cd $(FV_DIR) && ./run_all.sh
	@echo "=== all proofs passed ==="

clean:
	rm -rf $(BUILD) xsim.dir *.jou *.log *.pb webtalk*
	@find $(FV_DIR) -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
