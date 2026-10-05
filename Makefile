# -----------------------------------------------------------------------------
# Makefile : APB UVM VIP, Questa flow
#
#   make run TEST=apb_smoke_test SEED=1        one test, one seed
#   make regress SEEDS="1 2 3"                 all TESTS x SEEDS, then merge + report
#   make merge report html                     coverage merge / text report / HTML report
#   make gui TEST=apb_reset_test EXTRA_PLUSARGS="+MID_RESET_AT=300 +MID_RESET_LEN=4"
#   make clean
#
# Pass/fail comes from check_log.sh (UVM report summary), not the simulator exit code.
# Questa ships a pre-compiled UVM library, so no UVM include path is needed;
# set UVM_HOME=<path to uvm src dir parent> only for installs that need it.
# -----------------------------------------------------------------------------
TEST           ?= apb_regression_test
SEED           ?= 1
VERB           ?= UVM_MEDIUM
TESTS          ?= apb_smoke_test apb_regression_test apb_random_test apb_reset_test
SEEDS          ?= 1 2 3
EXTRA_PLUSARGS ?=
CODECOV        ?= 0
OUT            ?= out
COV_DIR        := $(OUT)/cov
LOG_DIR        := $(OUT)/log
STAMP          := work/.compiled

SRCS := apb_if.sv apb_pkg.sv apb_seq_item.sv apb_monitor.sv apb_mem_model.sv \
        apb_slave_driver.sv apb_agent_config.sv apb_slave_sequencer.sv apb_agent.sv \
        apb_master_driver.sv apb_master_agent.sv apb_slave_seq_lib.sv \
        apb_scoreboard.sv apb_coverage.sv apb_master_seq_lib.sv apb_env.sv \
        apb_tests.sv tb_top.sv

VLOG_FLAGS := -sv -timescale 1ns/1ps +incdir+.
ifdef UVM_HOME
VLOG_FLAGS += +incdir+$(UVM_HOME)/src
endif

COV_SAVE_OPTS := -assert -directive -cvg
ifeq ($(CODECOV),1)
VLOG_FLAGS    += +cover=bcesfx
COV_SAVE_OPTS += -codeAll
endif

VSIM_FLAGS := -c -coverage -voptargs="+acc"

.PHONY: all help comp run regress merge report html gui clean

all: run

help:
	@echo "targets: comp run regress merge report html gui clean"
	@echo "vars   : TEST SEED SEEDS TESTS VERB EXTRA_PLUSARGS CODECOV UVM_HOME"

comp: $(STAMP)

$(STAMP): $(SRCS)
	@[ -d work ] || vlib work
	vlog $(VLOG_FLAGS) -work work -l comp.log apb_if.sv apb_pkg.sv apb_tests.sv tb_top.sv
	@mkdir -p work
	@touch $(STAMP)

run: $(STAMP)
	@mkdir -p $(COV_DIR) $(LOG_DIR)
	vsim $(VSIM_FLAGS) -sv_seed $(SEED) work.tb_top \
	  +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(EXTRA_PLUSARGS) \
	  -l $(LOG_DIR)/$(TEST)_$(SEED).log \
	  -do "coverage save -onexit $(COV_SAVE_OPTS) $(COV_DIR)/$(TEST)_$(SEED).ucdb; run -all; quit -f"
	@sh ./check_log.sh $(LOG_DIR)/$(TEST)_$(SEED).log

regress: $(STAMP)
	@fail=0; \
	for t in $(TESTS); do \
	  for s in $(SEEDS); do \
	    extra=""; \
	    if [ "$$t" = "apb_reset_test" ]; then extra="+MID_RESET_AT=300 +MID_RESET_LEN=4"; fi; \
	    $(MAKE) --no-print-directory run TEST=$$t SEED=$$s EXTRA_PLUSARGS="$$extra" || fail=1; \
	  done; \
	done; \
	$(MAKE) --no-print-directory merge report; \
	exit $$fail

merge:
	@files=$$(ls $(COV_DIR)/*.ucdb 2>/dev/null | grep -v merged.ucdb); \
	if [ -z "$$files" ]; then echo "no UCDB files in $(COV_DIR)"; exit 1; fi; \
	vcover merge -out $(COV_DIR)/merged.ucdb $$files

report:
	vcover report -details -output $(COV_DIR)/merged_report.txt $(COV_DIR)/merged.ucdb
	@echo "coverage report: $(COV_DIR)/merged_report.txt"

html:
	vcover report -html -htmldir $(COV_DIR)/html $(COV_DIR)/merged.ucdb
	@echo "coverage html: $(COV_DIR)/html/index.html"

gui: $(STAMP)
	vsim -gui -coverage -voptargs="+acc" -sv_seed $(SEED) work.tb_top \
	  +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(EXTRA_PLUSARGS) \
	  -do "add wave -r /tb_top/apb_vif/*; run -all"

clean:
	rm -rf work out comp.log transcript vsim.wlf *.ucdb
