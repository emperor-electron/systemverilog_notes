# =============================================================================
# SystemVerilog notes -- lint and regression driver.
#
#   make            # lint everything, then run every test
#   make lint       # Verilator lint over all RTL and arithmetic modules
#   make sim        # run every testbench
#   make <name>     # run one test (see TESTS below)
#   make clean
#
# Two simulators are used deliberately, because neither one alone is enough:
#
#   Icarus Verilog  4-state. Models X propagation, and supports `shortreal`
#                   (needed to use the host FPU as a floating-point reference).
#                   Does NOT support clocking blocks, and its concurrent
#                   assertion support covers only simple boolean properties --
#                   the implication operators |-> and |=> are rejected outright.
#                   Any module using them must be simulated in Verilator.
#
#   Verilator       2-state, very fast, excellent linter, supports clocking
#                   blocks with --timing. Cannot model X propagation, so it
#                   cannot find an uninitialized-register bug -- see docs/02.
#
# Tool flags worth knowing (all learned the hard way):
#   iverilog -g2012                 enable SystemVerilog-2012
#            -gsupported-assertions accept concurrent assertions
#            -Y.sv -y DIR           library search with a .sv suffix
#                                   (the default suffix is .v, so -y alone
#                                    silently finds nothing)
#   verilator --binary --timing     build a standalone simulation executable
#             --timescale 1ns/1ps   supply a default timescale so that files
#                                   without one do not trip TIMESCALEMOD
#             -y DIR                library search (needs file name == module
#                                    name, which is why this repo uses one
#                                    module per file)
# =============================================================================

IVERILOG    ?= iverilog
VVP         ?= vvp
VERILATOR   ?= verilator

RTL_DIR      = examples/rtl
ARITH_DIR    = examples/arith
TB_DIR       = examples/tb
BUILD        = build

IV_FLAGS     = -g2012 -gsupported-assertions -Y.sv -y $(RTL_DIR) -y $(ARITH_DIR)
VL_FLAGS     = --binary --timing --timescale 1ns/1ps -Wno-fatal \
               -y $(RTL_DIR) -y $(ARITH_DIR)

# MULTITOP/DECLFILENAME are file-layout warnings; UNUSED* fires on packages that
# legitimately export more than any one consumer needs; SYNCASYNCNET fires on
# `disable iff (!rst_n)` in an assertion, which is correct practice.
LINT_FLAGS   = --lint-only -Wall --timing --timescale 1ns/1ps \
               -Wno-MULTITOP -Wno-DECLFILENAME -Wno-SYNCASYNCNET \
               -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
               -y $(RTL_DIR) -y $(ARITH_DIR)

PKGS         = $(ARITH_DIR)/fp_pkg.sv $(ARITH_DIR)/fixed_pkg.sv
RTL_SRCS     = $(wildcard $(RTL_DIR)/*.sv)
ARITH_SRCS   = $(filter-out $(PKGS),$(wildcard $(ARITH_DIR)/*.sv))

# Tests that need a 4-state simulator or `shortreal`  -> Icarus
IV_TESTS     = signedness width_rules fp arith
# Tests that need clocking blocks                     -> Verilator
VL_TESTS     = fifo async_fifo skid smoke pipeline

TESTS        = $(IV_TESTS) $(VL_TESTS)

.PHONY: all lint sim clean $(TESTS)

all: lint sim

# -----------------------------------------------------------------------------
# Lint
# -----------------------------------------------------------------------------
lint:
	@echo "=== lint: $(words $(RTL_SRCS) $(ARITH_SRCS)) files ==="
	@fail=0; \
	for f in $(RTL_SRCS) $(ARITH_SRCS); do \
	  out=$$($(VERILATOR) $(LINT_FLAGS) $(PKGS) $$f 2>&1); \
	  if echo "$$out" | grep -q '%Error\|%Warning'; then \
	    echo "--- $$f"; echo "$$out" | grep -A4 '%Error\|%Warning' | head -20; \
	    fail=1; \
	  fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "lint: CLEAN"; else echo "lint: FAILED"; exit 1; fi

# -----------------------------------------------------------------------------
# Simulation
# -----------------------------------------------------------------------------
sim: $(TESTS)
	@echo ""
	@echo "=== all tests passed ==="

$(BUILD):
	@mkdir -p $(BUILD)

# ---- Icarus tests -----------------------------------------------------------
# The two demo files are standalone: they take no DUT.
signedness: | $(BUILD)
	@echo "=== signedness_demo (Icarus, 4-state) ==="
	@$(IVERILOG) $(IV_FLAGS) -o $(BUILD)/signedness.vvp \
	    $(ARITH_DIR)/signedness_demo.sv 2>&1 | grep -v 'sorry:' || true
	@$(VVP) $(BUILD)/signedness.vvp

width_rules: | $(BUILD)
	@echo "=== width_rules_tb (Icarus) ==="
	@$(IVERILOG) $(IV_FLAGS) -o $(BUILD)/width_rules.vvp \
	    $(ARITH_DIR)/width_rules_tb.sv 2>&1 | grep -v 'sorry:' || true
	@$(VVP) $(BUILD)/width_rules.vvp

# Needs `shortreal` to use the host FPU as the golden reference.
fp: | $(BUILD)
	@echo "=== fp_tb: fp_add + fp_mul vs the host FPU (Icarus) ==="
	@$(IVERILOG) $(IV_FLAGS) -o $(BUILD)/fp.vvp \
	    $(PKGS) $(TB_DIR)/fp_tb.sv 2>&1 | grep -v 'sorry:' || true
	@$(VVP) $(BUILD)/fp.vvp

arith: | $(BUILD)
	@echo "=== arith_tb: divider, saturation, CORDIC, FIR, MAC (Icarus) ==="
	@$(IVERILOG) $(IV_FLAGS) -o $(BUILD)/arith.vvp \
	    $(TB_DIR)/arith_tb.sv 2>&1 | grep -v 'sorry:' || true
	@$(VVP) $(BUILD)/arith.vvp

# ---- Verilator tests (need clocking blocks) ---------------------------------
fifo: | $(BUILD)
	@echo "=== fifo_tb: layered TB with a clocking block (Verilator) ==="
	@$(VERILATOR) $(VL_FLAGS) -o fifo_tb --Mdir $(BUILD)/obj_fifo \
	    $(TB_DIR)/fifo_tb.sv
	@$(BUILD)/obj_fifo/fifo_tb

async_fifo: | $(BUILD)
	@echo "=== async_fifo_tb: dual-clock, four clock ratios (Verilator) ==="
	@$(VERILATOR) $(VL_FLAGS) -o async_fifo_tb --Mdir $(BUILD)/obj_afifo \
	    $(TB_DIR)/async_fifo_tb.sv
	@$(BUILD)/obj_afifo/async_fifo_tb

skid: | $(BUILD)
	@echo "=== skid_buffer_tb: handshake + throughput check (Verilator) ==="
	@$(VERILATOR) $(VL_FLAGS) -o skid_buffer_tb --Mdir $(BUILD)/obj_skid \
	    $(TB_DIR)/skid_buffer_tb.sv
	@$(BUILD)/obj_skid/skid_buffer_tb

smoke: | $(BUILD)
	@echo "=== rtl_smoke_tb: arbiters, encoders, CRC, LFSR, UART (Verilator) ==="
	@$(VERILATOR) $(VL_FLAGS) -o rtl_smoke_tb --Mdir $(BUILD)/obj_smoke \
	    $(TB_DIR)/rtl_smoke_tb.sv
	@$(BUILD)/obj_smoke/rtl_smoke_tb

# pipe_ctrl uses |=> in its assertions, which Icarus cannot parse -- hence
# Verilator rather than the 4-state engine.
pipeline: | $(BUILD)
	@echo "=== pipeline_tb: delay line, pipe control, trees, accumulators ==="
	@$(VERILATOR) $(VL_FLAGS) -o pipeline_tb --Mdir $(BUILD)/obj_pipe \
	    $(TB_DIR)/pipeline_tb.sv
	@$(BUILD)/obj_pipe/pipeline_tb

# Cross-check the language demos on Verilator too. They are written to detect a
# 2-state engine and skip the one X-propagation check it cannot model.
xcheck: | $(BUILD)
	@echo "=== signedness_demo + width_rules_tb on Verilator (2-state) ==="
	@$(VERILATOR) $(VL_FLAGS) -o signedness --Mdir $(BUILD)/obj_sd \
	    $(ARITH_DIR)/signedness_demo.sv
	@$(BUILD)/obj_sd/signedness
	@$(VERILATOR) $(VL_FLAGS) -o width_rules --Mdir $(BUILD)/obj_wr \
	    $(ARITH_DIR)/width_rules_tb.sv
	@$(BUILD)/obj_wr/width_rules

clean:
	rm -rf $(BUILD) obj_dir *.vvp
