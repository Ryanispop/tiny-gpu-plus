import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger

# Helper to reliably restart the GPU
async def reset_and_start(dut, threads):
    # 1. Hard Reset (Clears 'done' and internal state)
    dut.start.value = 0
    dut.reset.value = 1
    await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)
    
    # 2. Set Thread Count
    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = threads
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0
    await RisingEdge(dut.clk)
    
    # 3. Pulse Start
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

@cocotb.test()
async def test_sequential(dut):
    logger.info(">>> RUNNING SEQUENTIAL MATMUL (Run Twice)")
    
    # --- 1. USE YOUR WORKING MATMUL KERNEL ---
    program = [
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b0011000000001111, # ADD R0, R0, %threadIdx
        0b1001000100000001, # CONST R1, #1
        0b1001001000000010, # CONST R2, #2 (N=2)
        0b1001001100000000, # CONST R3, #0 (Base A)
        0b1001010000000100, # CONST R4, #4 (Base B)
        0b1001010100001000, # CONST R5, #8 (Base C)
        0b0110011000000010, # DIV R6, R0, R2
        0b0101011101100010, # MUL R7, R6, R2
        0b0100011100000111, # SUB R7, R0, R7
        0b1001100000000000, # CONST R8, #0
        0b1001100100000000, # CONST R9, #0
        # LOOP:
        0b0101101001100010, 0b0011101010101001, 0b0011101010100011, 
        0b0111101010100000, # LDR A (Potential Stall)
        0b0101101110010010, 0b0011101110110111, 0b0011101110110100, 
        0b0111101110110000, # LDR B (Potential Stall)
        0b0101110010101011, 0b0011100010001100, 0b0011100110010001, 
        0b0010000010010010, 0b0001100000001100, 
        0b0011100101010000, 
        0b1000000010011000, # STR C
        0b1111000000000000  # RET
    ]
    
    # Same Memory Setup
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    
    # 2x2 Matrices
    data = [1, 2, 3, 4,  1, 2, 3, 4] 

    # --- 2. INITIALIZE (Run Setup Once) ---
    # We pass threads=4 here just to get the simulation started
    await setup(dut, program_memory, program, data_memory, data, threads=4)

    # --- 3. BATCH 1 (4 Threads) ---
    logger.info(">>> Starting Batch 1...")
    await reset_and_start(dut, threads=4)

    cycles_1 = 0
    while dut.done.value != 1:
        # INJECT LATENCY: Run memory every 4 cycles to highlight speedup later
        if cycles_1 % 4 == 0: 
            data_memory.run()
        program_memory.run()
        await RisingEdge(dut.clk)
        cycles_1 += 1
        if cycles_1 > 5000: break # Safety

    logger.info(f"Batch 1 finished in {cycles_1} cycles")

    # --- 4. BATCH 2 (4 Threads) ---
    logger.info(">>> Starting Batch 2...")
    await reset_and_start(dut, threads=4)
    
    cycles_2 = 0
    while dut.done.value != 1:
        if cycles_2 % 4 == 0: 
            data_memory.run()
        program_memory.run()
        await RisingEdge(dut.clk)
        cycles_2 += 1
        if cycles_2 > 5000: break

    logger.info(f"Batch 2 finished in {cycles_2} cycles")
    
    # --- 5. RESULT ---
    total = cycles_1 + cycles_2
    logger.info("==========================================")
    logger.info(f"TOTAL SEQUENTIAL TIME: {total}")
    logger.info("==========================================")