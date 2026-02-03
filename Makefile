.PHONY: test compile

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)

test_matadd: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_matadd \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

test_matmul: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_matmul \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

test_priority: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_priority \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

compile:
	make compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	sv2v -w build/$*.v src/$*.sv

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^

