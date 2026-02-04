import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger

def safe_bits(sig) -> str:
    s = str(sig.value)  # may contain X/Z
    return s.replace("x","0").replace("X","0").replace("z","0").replace("Z","0")

def safe_int(sig) -> int:
    return int(safe_bits(sig), 2)

def get_packed_field(sig, idx: int, width: int, n: int, lsb_first=True) -> int:
    val = safe_int(sig)
    if lsb_first:
        return (val >> (idx * width)) & ((1 << width) - 1)
    shift = (n - 1 - idx) * width
    return (val >> shift) & ((1 << width) - 1)

@cocotb.test()
async def test_block_order_trace(dut):
    # Program Memory
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")

    # 4x4 matmul program (same one you've been using)
    program = [
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b0011000000001111, # ADD R0, R0, %threadIdx
        0b1001000100000001, # CONST R1, #1
        0b1001001000000100, # CONST R2, #4
        0b1001001100000000, # CONST R3, #0
        0b1001010000010000, # CONST R4, #16  baseB
        0b1001010100100000, # CONST R5, #32  baseC
        0b0110011000000010, # DIV R6, R0, R2
        0b0101011101100010, # MUL R7, R6, R2
        0b0100011100000111, # SUB R7, R0, R7
        0b1001100000000000, # CONST R8, #0
        0b1001100100000000, # CONST R9, #0
        0b0101101001100010,
        0b0011101010101001,
        0b0011101010100011,
        0b0111101010100000,
        0b0101101110010010,
        0b0011101110110111,
        0b0011101110110100,
        0b0111101110110000,
        0b0101110010101011,
        0b0011100010001100,
        0b0011100110010001,
        0b0010000010010010,
        0b0001100000001100,
        0b0011100101010000,
        0b1000000010011000,
        0b1111000000000000
    ]

    # Data Memory
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")

    A = [
        1,2,3,4,
        5,6,7,8,
        9,10,11,12,
        13,14,15,16
    ]
    B = [
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1
    ]
    data = A + B  # C written at baseC=32

    # Use more blocks so ordering is obvious:
    # TPB=4 => threads=32 gives 8 blocks (0..7)
    threads = 32

    await setup(dut, program_memory, program, data_memory, data, threads)

    NUM_CORES = 2
    TIMEOUT = 200000

    prev_start = 0
    prev_done = 0

    dispatch_events = []
    done_events = []

    cycles = 0
    while int(dut.done.value) != 1:
        data_memory.run()
        program_memory.run()

        start_vec = safe_int(dut.core_start)
        done_vec  = safe_int(dut.core_done)

        start_rise = start_vec & (~prev_start)
        done_rise  = done_vec  & (~prev_done)

        for c in range(NUM_CORES):
            if (start_rise >> c) & 1:
                bid = get_packed_field(dut.core_block_id, c, width=8, n=NUM_CORES, lsb_first=True)
                dispatch_events.append((cycles, c, bid))
                logger.info(f"[cycle {cycles}] core{c} START block {bid}")

            if (done_rise >> c) & 1:
                bid = get_packed_field(dut.core_block_id, c, width=8, n=NUM_CORES, lsb_first=True)
                done_events.append((cycles, c, bid))
                logger.info(f"[cycle {cycles}] core{c} DONE  block {bid}")

        prev_start = start_vec
        prev_done = done_vec

        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > TIMEOUT:
            assert False, f"Timeout waiting for done (>{TIMEOUT} cycles)"

    dispatch_order = [b for (_, _, b) in dispatch_events]
    done_order = [b for (_, _, b) in done_events]

    logger.info("====================================")
    logger.info(f"TOTAL cycles: {cycles}")
    logger.info(f"DISPATCH ORDER: {dispatch_order}")
    logger.info(f"DONE ORDER:     {done_order}")
    logger.info("====================================")
