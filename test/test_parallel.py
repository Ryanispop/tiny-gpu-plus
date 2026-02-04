import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger

@cocotb.test()
async def test_parallel(dut):
    logger.info(">>> RUNNING PARALLEL TEST (8 threads at once)")
    
    # Same Program
    program = [
        0b0101000011011110, 0b1001000100000000, 0b0010000010000001, 0b0001001000000010, 
        0b1001001000000000, 0b0111001100100000, 0b1111000000000000, 
        0b0011000100010001, 0b0011000100010001, 0b0011000100010001, 0b0011000100010001, 0b1111000000000000
    ]
    
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 32 

    # SETUP FOR 8 THREADS (2 Blocks)
    await setup(dut, program_memory, program, data_memory, data, threads=8)

    # Force Hard Reset
    dut.start.value = 0
    dut.reset.value = 1
    await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)
    
    # Manual Start
    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = 8 # 8 Threads
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    cycles = 0
    while dut.done.value != 1:
        if cycles % 8 == 0: # Slow Memory
            data_memory.run()
        program_memory.run()
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 5000: 
            logger.error("FAIL: Simulation Timed Out!")
            break

    logger.info(f"TOTAL PARALLEL TIME: {cycles} cycles")