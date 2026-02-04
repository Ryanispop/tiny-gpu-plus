import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger

async def run_batch_robust(dut, threads, start_index=0):
    """
    Runs a batch with a hard reset to prevent 'Instant Finish' bugs.
    """
    
    # 1. SETUP MEMORY & PROGRAM
    # Block 0 -> Loads Memory (Stalls)
    # Block 1 -> Does Math (Runs in background)
    program = [
        # Block ID Check: R0 = blockIdx * blockDim
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b1001000100000000, # CONST R1, #0
        0b0010000010000001, # CMP R0, R1
        0b0001001000000010, # BRp #2 (Jump to Offset 2 if Positive -> Block 1)
        
        # PATH A: MEMORY STALL (Block 0)
        0b1001001000000000, # CONST R2, #0 
        0b0111001100100000, # LDR R3, R2 (STALLS HERE)
        0b1111000000000000, # RET
        
        # PATH B: MATH WORK (Block 1)
        0b0011000100010001, # ADD R1, R1, R1
        0b0011000100010001, # ADD R1, R1, R1
        0b0011000100010001, # ADD R1, R1, R1
        0b0011000100010001, # ADD R1, R1, R1
        0b1111000000000000, # RET
    ]

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 32 

    # 2. RUN STANDARD SETUP
    # This might trigger a race condition (Start before ThreadCount is ready).
    # We allow it to happen, then we fix it below.
    await setup(dut, program_memory, program, data_memory, data, threads)
    
    # --- FIX: FORCE RESET AND RESTART ---
    logger.info(f"   [Batch Start] Resetting GPU to ensure clean state for {threads} threads...")
    
    dut.start.value = 0           
    dut.reset.value = 1           # Assert Reset
    await RisingEdge(dut.clk)
    dut.reset.value = 0           # Release Reset
    await RisingEdge(dut.clk)
    
    # Re-write the thread count explicitly
    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = threads
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0
    
    # Wait 2 cycles for values to latch
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    
    # NOW assert Start
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0 
    
    # 3. EXECUTION LOOP
    cycles = 0
    while dut.done.value != 1:
        # Inject Latency: Memory responds only every 8 cycles
        if cycles % 8 == 0:
            data_memory.run()
        program_memory.run()
        
        await RisingEdge(dut.clk)
        cycles += 1
        
        # Safety Timeout (prevent infinite loops)
        if cycles > 2000:
            logger.error("Timeout! GPU stuck in infinite loop.")
            break
            
    return cycles

@cocotb.test()
async def test_comparison_2x4(dut):
    """
    Side-by-Side Comparison: Sequential (2x4) vs Parallel (1x8)
    """
    logger.info("==================================================")
    logger.info(" STARTING SIDE-BY-SIDE PRIORITY TEST")
    logger.info("==================================================")

    # --- SCENARIO 1: SEQUENTIAL ---
    logger.info(">>> SCENARIO 1: Sequential Run (4 threads, reset, 4 threads)")
    
    c1 = await run_batch_robust(dut, threads=4)
    logger.info(f"   Batch 1 finished: {c1} cycles")

    c2 = await run_batch_robust(dut, threads=4)
    logger.info(f"   Batch 2 finished: {c2} cycles")
    
    total_seq = c1 + c2
    logger.info(f"   >>> TOTAL SEQUENTIAL: {total_seq}")

    # --- SCENARIO 2: PARALLEL ---
    logger.info(">>> SCENARIO 2: Parallel Run (8 threads at once)")
    
    total_par = await run_batch_robust(dut, threads=8)
    logger.info(f"   >>> TOTAL PARALLEL: {total_par}")
    
    # --- RESULTS ---
    saved = total_seq - total_par
    logger.info("==================================================")
    logger.info(f" Sequential (Old): {total_seq} cycles")
    logger.info(f" Parallel (New):   {total_par} cycles")
    logger.info(f" Saved:            {saved} cycles")
    logger.info("==================================================")
    
    # Validation: Parallel should be faster than Sequential
    if total_par < total_seq:
        logger.info("PASS: Speedup Confirmed!")
    else:
        # CHANGED: Use info or generic print, as your logger lacks .error
        logger.info("FAIL: No speedup detected.") 
        assert False