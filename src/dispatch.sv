`default_nettype none
`timescale 1ns/1ns

// BLOCK DISPATCH (priority-based)
// - Dispatches blocks to available cores
// - Tracks which blocks have been dispatched (mask) and which are done
// - Uses a simple priority policy: highest block ID first
module dispatch #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input  wire clk,
    input  wire reset,
    input  wire start,

    // Kernel Metadata
    input  wire [7:0] thread_count,

    // Core States
    input  wire [NUM_CORES-1:0] core_done,
    output reg  [NUM_CORES-1:0] core_start,
    output reg  [NUM_CORES-1:0] core_reset,
    output reg  [7:0]           core_block_id     [NUM_CORES-1:0],
    output reg  [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0],

    // Kernel Execution
    output reg done
);

    // Total number of blocks = ceil(thread_count / THREADS_PER_BLOCK)
    wire [7:0] total_blocks;
    assign total_blocks = (thread_count + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    // Block bookkeeping
    reg [7:0] blocks_dispatched;
    reg [7:0] blocks_done;
    reg       start_execution;

    // Track which blocks have been dispatched (max 64 blocks for 8-bit threads and TPB=4)
    localparam int MAX_BLOCKS = 64;
    reg [MAX_BLOCKS-1:0] dispatched_mask;
    reg [MAX_BLOCKS-1:0] mask_next;

    // Core busy tracking (needed because core_start is a 1-cycle pulse)
    reg [NUM_CORES-1:0] core_busy;

    // Temp
    reg [7:0] bid;

    // Priority picker: highest block id first
    function automatic [7:0] pick_next_block(
        input [7:0] total,
        input [MAX_BLOCKS-1:0] mask
    );
        pick_next_block = 8'hFF; // none available
        for (int b = MAX_BLOCKS-1; b >= 0; b--) begin
            if (b < total && !mask[b]) begin
                pick_next_block = b[7:0];
                return;
            end
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            done             <= 1'b0;
            start_execution  <= 1'b0;
            blocks_dispatched<= 8'd0;
            blocks_done      <= 8'd0;

            dispatched_mask  <= '0;
            mask_next        <= '0;

            core_start       <= '0;
            core_reset       <= '1;   // reset all cores
            core_busy        <= '0;

            for (int i = 0; i < NUM_CORES; i++) begin
                core_block_id[i]     <= 8'd0;
                core_thread_count[i] <= THREADS_PER_BLOCK[$clog2(THREADS_PER_BLOCK):0];
            end
        end else if (start) begin
            // Make core_start a 1-cycle pulse by defaulting low each cycle
            core_start <= '0;
            // Latch the start of a kernel once (since start may be held high)
            if (!start_execution) begin
                start_execution   <= 1'b1;
                done              <= 1'b0;
                blocks_dispatched <= 8'd0;
                blocks_done       <= 8'd0;
                dispatched_mask   <= '0;
                mask_next         <= '0;
                core_busy         <= '0;

                // Kick all cores into reset so they are ready to accept a block
                core_reset <= '1;
            end

            // If all blocks are done, we're done
            if (total_blocks != 0 && blocks_done >= total_blocks) begin
                done            <= 1'b1;
                start_execution <= 1'b0;
            end

            // Prepare per-cycle shadow mask
            mask_next = dispatched_mask; // blocking copy

            // Dispatch new blocks to any core that is being reset (i.e., available)
            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_reset[i]) begin
                    core_reset[i] <= 1'b0;

                    if (blocks_dispatched < total_blocks) begin
                        bid = pick_next_block(total_blocks, mask_next);

                        if (bid != 8'hFF) begin
                            core_start[i]    <= 1'b1;
                            core_block_id[i] <= bid;

                            core_thread_count[i] <= (bid == total_blocks - 1)
                                ? thread_count - (bid * THREADS_PER_BLOCK)
                                : THREADS_PER_BLOCK;

                            // Update shadow mask immediately so the next core sees it this cycle
                            mask_next[bid] = 1'b1;

                            // Mark this core busy (since core_start is just a pulse)
                            core_busy[i] <= 1'b1;

                            blocks_dispatched <= blocks_dispatched + 1'b1;
                        end
                    end
                end
            end

            // Commit shadow mask
            dispatched_mask <= mask_next;

            // Completion detection: use core_busy, not core_start
            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_busy[i] && core_done[i]) begin
                    core_reset[i] <= 1'b1;   // recycle core for next block
                    core_busy[i]  <= 1'b0;
                    blocks_done   <= blocks_done + 1'b1;
                end
            end
        end
    end
endmodule
