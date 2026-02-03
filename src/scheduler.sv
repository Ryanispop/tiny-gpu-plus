`default_nettype none
`timescale 1ns/1ns

// SCHEDULER
// > Manages the entire control flow of a single compute core processing 1 block
// 1. FETCH - Retrieve instruction at current program counter (PC) from program memory
// 2. DECODE - Decode the instruction into the relevant control signals
// 3. REQUEST - If we have an instruction that accesses memory, trigger the async memory requests from LSUs
// 4. WAIT - Wait for all async memory requests to resolve (if applicable)
// 5. EXECUTE - Execute computations on retrieved data from registers / memory
// 6. UPDATE - Update register values (including NZP register) and program counter
// > Each core has it's own scheduler where multiple threads can be processed with
//   the same control flow at once.
// > Technically, different instructions can branch to different PCs, requiring "branch divergence." In
//   this minimal implementation, we assume no branch divergence (naive approach for simplicity)
module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
) (
    input wire clk,
    input wire reset,
    input wire start,
    
    //Context switching
    output reg active_context, // 0 or 1
    // We need to see BOTH LSU states to make decisions
    input reg [1:0] lsu_state_A [THREADS_PER_BLOCK-1:0],
    input reg [1:0] lsu_state_B [THREADS_PER_BLOCK-1:0],

    // Control Signals
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,
    input reg decoded_ret,

    // Memory Access State
    input reg [2:0] fetcher_state,
    input reg [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Current & Next PC
    output reg [7:0] current_pc,
    input reg [7:0] next_pc [THREADS_PER_BLOCK-1:0],

    // Execution State
    output reg [2:0] core_state,
    output reg done
);

    // Storage for 2 Contexts
    reg [7:0] pc_A, pc_B;
    reg [2:0] state_A, state_B;
    reg done_A, done_B;
    
    // Next State Logic
    reg [2:0] next_state; 
    reg [7:0] next_pc_val;

    localparam IDLE = 3'b000, // Waiting to start
        FETCH = 3'b001,       // Fetch instructions from program memory
        DECODE = 3'b010,      // Decode instructions into control signals
        REQUEST = 3'b011,     // Request data from registers or memory
        WAIT = 3'b100,        // Wait for response from memory if necessary
        EXECUTE = 3'b101,     // Execute ALU and PC calculations
        UPDATE = 3'b110,      // Update registers, NZP, and PC
        DONE = 3'b111;        // Done executing this block
    
    // --- PRIORITY LOGIC ---
    always @(*) begin
        // Default: Stick with current
        // Prefer A. Only run B if A is Waiting or Done.
        if (state_A != WAIT && state_A != DONE && state_A != IDLE) 
            active_context = 0;
        else if (state_A == WAIT) 
            active_context = 1; // A is stuck, run B!
        else if (state_A == DONE && state_B != DONE) 
            active_context = 1;
        else 
            active_context = 0; // Default to A
            
        // Map outputs
        if (active_context == 0) begin
            current_pc = pc_A;
            core_state = state_A;
        end else begin
            current_pc = pc_B;
            core_state = state_B;
        end
        
        done = done_A && done_B;
    end

    always @(posedge clk) begin 
        if (reset) begin
            pc_A <= 0; pc_B <= 0;
            state_A <= IDLE; state_B <= IDLE;
            done_A <= 0; done_B <= 0;
        end else begin 
            next_state = core_state; // Default hold
            next_pc_val = current_pc;

            case (core_state)
                IDLE: begin
                    // Here after reset (before kernel is launched, or after previous block has been processed)
                    if (start) begin 
                        // Start by fetching the next instruction for this block based on PC
                        core_state <= FETCH;
                    end
                end
                FETCH: begin 
                    // Move on once fetcher_state = FETCHED
                    if (fetcher_state == 3'b010) begin 
                        core_state <= DECODE;
                    end
                end
                DECODE: begin
                    // Decode is synchronous so we move on after one cycle
                    core_state <= REQUEST;
                end
                REQUEST: begin 
                    // If we are Context B, and Context A is WAITING, we are NOT allowed to issue a memory request, because the bus is busy.
                     // We stall here until A finishes waiting.
                     if (active_context == 1 && state_A == WAIT && 
                        (decoded_mem_read_enable || decoded_mem_write_enable)) begin
                         next_state = REQUEST; // STALL
                     end else begin
                         next_state = WAIT;
                     end
                end
                WAIT: begin
                    // Wait for all LSUs to finish their request before continuing
                    reg any_waiting = 0;
                    for (int i=0; i<THREADS_PER_BLOCK; i++) begin
                        if (active_context == 0) begin
                            if (lsu_state_A[i] == 1 || lsu_state_A[i] == 2) any_waiting = 1;
                        end else begin
                            if (lsu_state_B[i] == 1 || lsu_state_B[i] == 2) any_waiting = 1;
                        end
                    end
                    if (!any_waiting) next_state = EXECUTE;
                end
                EXECUTE: begin
                    // Execute is synchronous so we move on after one cycle
                    core_state <= UPDATE;
                end
                UPDATE: begin 
                    if (decoded_ret) begin
                        next_state = DONE;
                        if(active_context == 0) done_A <= 1; else done_B <= 1;
                    end else begin
                        next_pc_val = next_pc[THREADS_PER_BLOCK-1];
                        next_state = FETCH;
                    end
                end
                DONE: begin 
                    // no-op
                end
            endcase

            if (active_context == 0) begin
                state_A <= next_state;
                if (core_state == UPDATE) pc_A <= next_pc_val;
            end else begin
                state_B <= next_state;
                if (core_state == UPDATE) pc_B <= next_pc_val;
            end
            
            // Handle Global Start (Kickoff both)
            if (state_A == IDLE && state_B == IDLE && start) begin
                state_A <= FETCH; state_B <= FETCH;
            end
        end
    end
endmodule
