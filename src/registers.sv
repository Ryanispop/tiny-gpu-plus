`default_nettype none
`timescale 1ns/1ns

// REGISTER FILE
// > Each thread within each core has it's own register file with 13 free registers and 3 read-only registers
// > Read-only registers hold the familiar %blockIdx, %blockDim, and %threadIdx values critical to SIMD
module registers #(
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 8
) (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some registers will be inactive

    //New input for conext switching
    input wire active_context,   //0 = Bloack A, 1 = Block B

    // Kernel Execution
    input reg [7:0] block_id,

    // State
    input reg [2:0] core_state,

    // Instruction Signals
    input reg [3:0] decoded_rd_address,
    input reg [3:0] decoded_rs_address,
    input reg [3:0] decoded_rt_address,

    // Control Signals
    input reg decoded_reg_write_enable,
    input reg [1:0] decoded_reg_input_mux,
    input reg [DATA_BITS-1:0] decoded_immediate,

    // Thread Unit Outputs
    input reg [DATA_BITS-1:0] alu_out,
    input reg [DATA_BITS-1:0] lsu_out,

    // Registers
    output reg [7:0] rs,
    output reg [7:0] rt
);
    localparam ARITHMETIC = 2'b00,
        MEMORY = 2'b01,
        CONSTANT = 2'b10;

    // DOUBLE SIZE: 32 registers (0-15 for Context 0, 16-31 for Context 1)
    reg [7:0] registers[31:0];

    //helper to calculate the register (0-15 for conext 0, 16-31 for conext 1
    function [4:0] get_addr(input [3:0] log_addr);
        get_addr = {active_context, log_addr}; // Prepend context bit
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            // Empty rs, rt
            rs <= 0;
            rt <= 0;
            // Initialize all free registers
            for (int i=0; i<32; i++) registers[i] <= 0;
            // Initialize read-only registers
            //Block 0 (13,14,15)
            registers[14] <= THREADS_PER_BLOCK; // %blockDim
            registers[15] <= THREAD_ID;         // %threadIdx
            //Block 1  (29,30,31)
            registers[30] <= THREADS_PER_BLOCK; // %blockDim
            registers[31] <= THREAD_ID;         // %threadIdx
        end else if (enable) begin 
            //update block_id for current context
            registers[get_addr(4'd13)] <= block_id;
            
            // Fill rs/rt when core_state = REQUEST
            if (core_state == 3'b011) begin 
                rs <= registers[get_addr(decoded_rs_address)];
                rt <= registers[get_addr(decoded_rt_address)];
            end

            // Store rd when core_state = UPDATE
            if (core_state == 3'b110) begin 
                // Only allow writing to R0 - R12
                if (decoded_reg_write_enable && decoded_rd_address < 13) begin
                    case (decoded_reg_input_mux)
                        ARITHMETIC: begin 
                            // ADD, SUB, MUL, DIV
                            registers[get_addr(decoded_rd_address)] <= alu_out;
                        end
                        MEMORY: begin 
                            // LDR
                            registers[get_addr(decoded_rd_address)] <= lsu_out;
                        end
                        CONSTANT: begin 
                            // CONST
                            registers[get_addr(decoded_rd_address)] <= decoded_immediate;
                        end
                    endcase
                end
            end
        end
    end
endmodule
