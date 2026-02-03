`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE
// > Handles processing 1 block at a time
// > The core also has it's own scheduler to manage control flow
// > Each core contains 1 fetcher & decoder, and register files, ALUs, LSUs, PC for each thread
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input reg program_mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output reg [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output reg [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);
    // State
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [15:0] instruction;

    // --- NEW: SHADOW STATE SIGNALS (For Priority Scheduler) ---
    // We need separate arrays for Context A and Context B states
    wire [7:0] next_pc_A [THREADS_PER_BLOCK-1:0];
    wire [7:0] next_pc_B [THREADS_PER_BLOCK-1:0];
    wire [1:0] lsu_state_A [THREADS_PER_BLOCK-1:0];
    wire [1:0] lsu_state_B [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_out_A [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_out_B [THREADS_PER_BLOCK-1:0];

    // Intermediate Signals
    reg [7:0] current_pc;
    // Note: next_pc is now handled via the muxed signals below
    reg [7:0] rs[THREADS_PER_BLOCK-1:0];
    reg [7:0] rt[THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out[THREADS_PER_BLOCK-1:0];
    
    // Decoded Instruction Signals
    reg [3:0] decoded_rd_address;
    reg [3:0] decoded_rs_address;
    reg [3:0] decoded_rt_address;
    reg [2:0] decoded_nzp;
    reg [7:0] decoded_immediate;

    // Decoded Control Signals
    reg decoded_reg_write_enable;           // Enable writing to a register
    reg decoded_mem_read_enable;            // Enable reading from memory
    reg decoded_mem_write_enable;           // Enable writing to memory
    reg decoded_nzp_write_enable;           // Enable writing to NZP register
    reg [1:0] decoded_reg_input_mux;        // Select input to register
    reg [1:0] decoded_alu_arithmetic_mux;   // Select arithmetic operation
    reg decoded_alu_output_mux;             // Select operation in ALU
    reg decoded_pc_mux;                     // Select source of next PC
    reg decoded_ret;

    

    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction) 
    );

    // Decoder
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret)
    );

    wire [7:0] next_pc_muxed_wire [THREADS_PER_BLOCK-1:0];

    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .fetcher_state(fetcher_state),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        
        // NEW CONNECTIONS
        .lsu_state_A(lsu_state_A), // Pass array A
        .lsu_state_B(lsu_state_B), // Pass array B
        .next_pc(next_pc_muxed_wire), // Pass the MUXED next_pc
        
        .current_pc(current_pc),
        .done(done)
    );

    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            
            // ---------------------------------------------------------
            // MUX LOGIC: ROUTE SIGNALS BASED ON ACTIVE CONTEXT
            // ---------------------------------------------------------
            // The ALU and Register File need to know Who is running?
            // Temporary wires that carry the signals for the Active Block.
            reg [7:0] next_pc_muxed;
            reg [7:0] lsu_out_muxed;

            always @(*) begin
                if (scheduler_instance.active_context == 0) begin
                    next_pc_muxed = next_pc_A[i];
                    lsu_out_muxed = lsu_out_A[i];
                    
                    // Route LSU A to Memory Controller
                    data_mem_read_valid[i]   = lsu_read_valid_A[i];
                    data_mem_read_address[i] = lsu_read_address_A[i];
                    data_mem_write_valid[i]  = lsu_write_valid_A[i];
                    data_mem_write_address[i]= lsu_write_address_A[i];
                    data_mem_write_data[i]   = lsu_write_data_A[i];
                end else begin
                    next_pc_muxed = next_pc_B[i];
                    lsu_out_muxed = lsu_out_B[i];

                    // Route LSU B to Memory Controller
                    data_mem_read_valid[i]   = lsu_read_valid_B[i];
                    data_mem_read_address[i] = lsu_read_address_B[i];
                    data_mem_write_valid[i]  = lsu_write_valid_B[i];
                    data_mem_write_address[i]= lsu_write_address_B[i];
                    data_mem_write_data[i]   = lsu_write_data_B[i];
                end
            end
            
            // ALU
            alu alu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_output_mux(decoded_alu_output_mux),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            // ---------------------------------------------------------
            // DUAL LSUs due to conext switching
            // ---------------------------------------------------------
            // Intermediate wires to hold outputs from LSU A
            wire lsu_read_valid_A, lsu_write_valid_A;
            wire [7:0] lsu_read_address_A, lsu_write_address_A, lsu_write_data_A;

            lsu lsu_instance_A (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                // Only active if scheduler says Context 0
                .core_state( (scheduler_instance.active_context == 0) ? core_state : 3'b000 ),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .mem_read_valid(lsu_read_valid_A),
                .mem_read_address(lsu_read_address_A),
                .mem_read_ready(data_mem_read_ready[i]), // Shared Ready
                .mem_read_data(data_mem_read_data[i]),   // Shared Data
                .mem_write_valid(lsu_write_valid_A),
                .mem_write_address(lsu_write_address_A),
                .mem_write_data(lsu_write_data_A),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state_A[i]), // Connect to Shadow State A
                .lsu_out(lsu_out_A[i])
            );

            // Intermediate wires to hold outputs from LSU B
            wire lsu_read_valid_B, lsu_write_valid_B;
            wire [7:0] lsu_read_address_B, lsu_write_address_B, lsu_write_data_B;

            lsu lsu_instance_B (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                // Only active if scheduler says Context 1
                .core_state( (scheduler_instance.active_context == 1) ? core_state : 3'b000 ),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .mem_read_valid(lsu_read_valid_B),
                .mem_read_address(lsu_read_address_B),
                .mem_read_ready(data_mem_read_ready[i]), // Shared Ready
                .mem_read_data(data_mem_read_data[i]),   // Shared Data
                .mem_write_valid(lsu_write_valid_B),
                .mem_write_address(lsu_write_address_B),
                .mem_write_data(lsu_write_data_B),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state_B[i]), // Connect to Shadow State B
                .lsu_out(lsu_out_B[i])
            );

            // ---------------------------------------------------------
            // BANKED REGISTER FILE
            // ---------------------------------------------------------
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                // NEW INPUTS
                .active_context(scheduler_instance.active_context),
                .block_id(block_id),
                .core_state(core_state),
                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),
                .decoded_immediate(decoded_immediate),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out_muxed), // Feed MUXED LSU output
                .rs(rs[i]),
                .rt(rt[i])
            );

            // ---------------------------------------------------------
            // DUAL PCs
            // ---------------------------------------------------------
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance_A (
                .clk(clk),
                .reset(reset),
                .enable(scheduler_instance.active_context == 0 && i < thread_count),
                .core_state(core_state),
                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(current_pc),
                .next_pc(next_pc_A[i]) // Output to A
            );

            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance_B (
                .clk(clk),
                .reset(reset),
                .enable(scheduler_instance.active_context == 1 && i < thread_count),
                .core_state(core_state),
                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(current_pc),
                .next_pc(next_pc_B[i]) // Output to B
            );
        end
    endgenerate
endmodule
