`default_nettype none
`timescale 1ns/1ns

module simt_stack #(
    parameter STACK_DEPTH = 8,
    parameter PC_WIDTH = 8,
    parameter MASK_WIDTH = 4
) (
    input wire clk,
    input wire reset,

    input wire push,
    input wire pop,
    input wire [PC_WIDTH-1:0] push_pc,
    input wire [MASK_WIDTH-1:0] push_mask,

    output wire [PC_WIDTH-1:0] top_pc,
    output wire [MASK_WIDTH-1:0] top_mask,
    output wire empty,
    output wire full
);

    reg [PC_WIDTH-1:0] pc_stack [STACK_DEPTH-1:0];
    reg [MASK_WIDTH-1:0] mask_stack [STACK_DEPTH-1:0];
    reg [$clog2(STACK_DEPTH):0] sp; // Stack Pointer

    assign empty = (sp == 0);
    assign full = (sp == STACK_DEPTH);

    // Top of stack is sp-1 because sp points to the next free slot
    // If empty, output 0 (or undefined)
    assign top_pc = (sp > 0) ? pc_stack[sp-1] : {PC_WIDTH{1'b0}};
    assign top_mask = (sp > 0) ? mask_stack[sp-1] : {MASK_WIDTH{1'b0}};

    always @(posedge clk) begin
        if (reset) begin
            sp <= 0;
            // Initialize for simulation cleanliness
            for (integer i = 0; i < STACK_DEPTH; i = i + 1) begin
                pc_stack[i] <= 0;
                mask_stack[i] <= 0;
            end
        end else begin
            if (push && !full) begin
                pc_stack[sp] <= push_pc;
                mask_stack[sp] <= push_mask;
                sp <= sp + 1;
            end else if (pop && !empty) begin
                sp <= sp - 1;
            end
        end
    end

endmodule
