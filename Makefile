.PHONY: compile test_matadd test_matmul test_priority test_sidebyside test_parallel test_sequential

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)

PYGPI_PYTHON_BIN?=$(shell which python)


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

test_sidebyside: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_sidebyside \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

test_parallel: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_parallel \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

test_sequential: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_sequential \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

test_blockorder: compile
	PYGPI_PYTHON_BIN=$(shell which python) \
	PYTHONPATH=. \
	COCOTB_TEST_MODULES=test.test_blockorder \
	vvp -M $(shell cocotb-config --lib-dir) -m $(shell cocotb-config --lib-name vpi icarus) build/sim.vvp

compile:
	sv2v -I src -w build/gpu.v src/*.sv
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v
	iverilog -g2012 -o build/sim.vvp build/gpu.v






compile_%:
	sv2v -w build/$*.v src/$*.sv

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^

