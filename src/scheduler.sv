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
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    input wire start,
    
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
    output wire [THREADS_PER_BLOCK-1:0] active_mask_out,
    output reg done
);
    localparam IDLE = 3'b000, // Waiting to start
        FETCH = 3'b001,       // Fetch instructions from program memory
        DECODE = 3'b010,      // Decode instructions into control signals
        REQUEST = 3'b011,     // Request data from registers or memory
        WAIT = 3'b100,        // Wait for response from memory if necessary
        EXECUTE = 3'b101,     // Execute ALU and PC calculations
        UPDATE = 3'b110,      // Update registers, NZP, and PC
        DONE = 3'b111;        // Done executing this block

    // Branch Divergence Logic
    reg [THREADS_PER_BLOCK-1:0] active_mask;
    assign active_mask_out = active_mask;

    // SIMT Stack Interface
    reg stack_push;
    reg stack_pop;
    reg [7:0] stack_push_pc;
    reg [THREADS_PER_BLOCK-1:0] stack_push_mask;
    wire [7:0] stack_top_pc;
    wire [THREADS_PER_BLOCK-1:0] stack_top_mask;
    wire stack_empty;
    wire stack_full;

    simt_stack #(
        .STACK_DEPTH(8),
        .PC_WIDTH(8),
        .MASK_WIDTH(THREADS_PER_BLOCK)
    ) simt_stack_instance (
        .clk(clk),
        .reset(reset),
        .push(stack_push),
        .pop(stack_pop),
        .push_pc(stack_push_pc),
        .push_mask(stack_push_mask),
        .top_pc(stack_top_pc),
        .top_mask(stack_top_mask),
        .empty(stack_empty),
        .full(stack_full)
    );

    always @(posedge clk) begin 
        // Default stack control
        stack_push <= 0;
        stack_pop <= 0;

        if (reset) begin
            current_pc <= 0;
            core_state <= IDLE;
            done <= 0;
            active_mask <= {THREADS_PER_BLOCK{1'b1}};
        end else begin 
            case (core_state)
                IDLE: begin
                    // Here after reset (before kernel is launched, or after previous block has been processed)
                    if (start) begin 
                        // Start by fetching the next instruction for this block based on PC
                        core_state <= FETCH;
                        active_mask <= {THREADS_PER_BLOCK{1'b1}};
                    end
                end
                FETCH: begin 
                    // Check for Re-convergence
                    // If current PC matches the PC on top of the stack, pop and merge
                    if (!stack_empty && current_pc == stack_top_pc) begin
                        active_mask <= active_mask | stack_top_mask;
                        stack_pop <= 1;
                        // Stay in FETCH, simply update mask and retry? 
                        // Actually, if we merge, we just continue fetching current_pc with more threads.
                    end

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
                    // Request is synchronous so we move on after one cycle
                    core_state <= WAIT;
                end
                WAIT: begin
                    // Wait for all LSUs to finish their request before continuing
                    reg any_lsu_waiting = 1'b0;
                    for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                        // Only check ACTIVE threads
                        if (active_mask[i] && (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10)) begin
                            any_lsu_waiting = 1'b1;
                            break;
                        end
                    end

                    // If no LSU is waiting for a response, move onto the next stage
                    if (!any_lsu_waiting) begin
                        core_state <= EXECUTE;
                    end
                end
                EXECUTE: begin
                    // Execute is synchronous so we move on after one cycle
                    core_state <= UPDATE;
                end
                UPDATE: begin 
                    if (decoded_ret) begin 
                        // If we reach a RET instruction, this block is done executing
                        done <= 1;
                        core_state <= DONE;
                    end else begin 
                        // Divergence Handling
                        reg [7:0] next_pc_consensus;
                        reg [THREADS_PER_BLOCK-1:0] diverge_mask;
                        reg has_divergence;
                        reg first_active_found;
                        reg [7:0] target_pc;
                        reg [THREADS_PER_BLOCK-1:0] mask_fallthrough;
                        reg [THREADS_PER_BLOCK-1:0] mask_target;
                        
                        has_divergence = 0;
                        diverge_mask = 0;
                        next_pc_consensus = current_pc + 1; // Default fall-through
                        first_active_found = 0;
                        target_pc = 0;
                        mask_fallthrough = 0;
                        mask_target = 0;

                        // 1. Determine "Fall-through" PC vs "Branch" PC
                        // Naive approach: Look at first active thread
                        
                        for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                            if (active_mask[i]) begin
                                if (!first_active_found) begin
                                    next_pc_consensus = next_pc[i];
                                    first_active_found = 1;
                                end else if (next_pc[i] != next_pc_consensus) begin
                                    has_divergence = 1;
                                end
                            end
                        end
                        
                        if (has_divergence) begin
                            // ... existing divergence logic ...
                            // We have some threads wanting PC+1 (Fall-through) and some wanting Target.
                            // Priority: Execute Fall-through first? Or Target? 
                            // Usually Stack pushes the "Post-Dominator" or the "Else" block.
                            // Let's assume we push the TARGET path and execute FALL-THROUGH first?
                            // Or vice-versa.
                            // Since we don't know which is jump (target) vs fallthrough easily without comparing to current_pc+1
                            
                            reg [7:0] target_pc;
                            reg [THREADS_PER_BLOCK-1:0] mask_fallthrough;
                            reg [THREADS_PER_BLOCK-1:0] mask_target;
                            
                            target_pc = 0;
                            mask_fallthrough = 0;
                            mask_target = 0;

                            // Find target PC (the one that isn't current_pc + 1)
                            for (int i=0; i<THREADS_PER_BLOCK; i++) begin
                                if (active_mask[i]) begin
                                    if (next_pc[i] != (current_pc + 1)) begin
                                        target_pc = next_pc[i];
                                    end
                                end
                            end

                            for (int i=0; i<THREADS_PER_BLOCK; i++) begin
                                if (active_mask[i]) begin
                                    if (next_pc[i] == (current_pc + 1)) begin
                                        mask_fallthrough[i] = 1;
                                    end else begin
                                        mask_target[i] = 1;
                                    end
                                end
                            end
                            
                            // If NO threads want fallthrough (all diverge to same target logic but my first loop failed?)
                            // No, if has_divergence is true, at least one thread differs from consensus.
                            // But what if consensus WAS target?
                            // My first loop picks First Active as consensus.
                            // If T0 jumps, output is Jump Target.
                            // If T1 falls through, T1 != T0. Divergence!
                            // Then I assume Fallthrough is "PC+1".
                            // If T0 jumped, mask_target gets T0. target_pc gets T0's target.
                            // If T1 fell through, mask_fallthrough gets T1.
                            
                            // Check valid split
                            if (mask_fallthrough == 0) begin
                                // Everyone branching to DIFFERENT targets? Or everyone branching to same target but I flagged divergence?
                                // If mask_fallthrough is 0, then everyone is in mask_target.
                                // But if everyone is in mask_target, then has_divergence should be false?
                                // Why? Because consensus was target. Everyone matches target.
                                // If T0 jumps to 10. Consensus=10.
                                // T1 jumps to 10. Match.
                                // has_divergence = 0.
                                // So we enter `else` block.
                            end

                            // Push TARGET scope to stack
                            stack_push <= 1;
                            stack_push_pc <= target_pc;
                            stack_push_mask <= mask_target;
                            
                            // Continue with FALL-THROUGH
                            active_mask <= mask_fallthrough;
                            current_pc <= current_pc + 1;

                        end else begin
                            // No divergence, all active threads agree
                            current_pc <= next_pc_consensus;
                        end

                        // Update is synchronous so we move on after one cycle
                        core_state <= FETCH;
                    end
                end
                DONE: begin 
                    // no-op
                end
            endcase
            
            // Handle Stack Pop Effect from FETCH state (takes 1 cycle)
            if (stack_pop) begin
                // active_mask was already updated combinatorially? No, it's sequential.
                // In FETCH: active_mask <= active_mask | stack_top_mask;
                // This will take effect in the NEXT cycle (DECODE).
                // But current_pc assumes we are fetching for the *current* mask?
                // Actually re-convergence checks if current_pc == top_pc.
                // If we pop, we stay at current_pc (because it matches) but we add threads.
                // So the instruction at current_pc will be executed by BOTH the existing threads AND the popped threads.
                // This is correct behavior for re-convergence at the start of a block/instruction.
            end
        end
    end
endmodule
