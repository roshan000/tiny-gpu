`default_nettype none
`timescale 1ns/1ns

module icache #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire reset,

    // CPU side (Fetcher)
    input wire valid_in,
    input wire [ADDR_BITS-1:0] addr_in,
    output reg ready_out,
    output reg [DATA_BITS-1:0] data_out,

    // Memory side (Global Memory)
    output reg mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address,
    input wire mem_read_ready,
    input wire [DATA_BITS-1:0] mem_read_data
);

    // Cache Parameters
    // 16 entries -> 4 bits index
    // Tag = 8 - 4 = 4 bits
    localparam INDEX_BITS = 4;
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;
    localparam CACHE_SIZE = 1 << INDEX_BITS;

    // Cache Storage
    reg [DATA_BITS-1:0] cache_data [CACHE_SIZE-1:0];
    reg [TAG_BITS-1:0] cache_tag [CACHE_SIZE-1:0];
    reg valid_bit [CACHE_SIZE-1:0];

    // Request parsing
    wire [INDEX_BITS-1:0] index;
    wire [TAG_BITS-1:0] tag;
    assign index = addr_in[INDEX_BITS-1:0];
    assign tag = addr_in[ADDR_BITS-1:INDEX_BITS];

    // State Machine
    localparam IDLE = 0;
    localparam COMPARE = 1;
    localparam ALLOCATE = 2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            ready_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            // Invalidate all cache entries
            for (integer i = 0; i < CACHE_SIZE; i = i + 1) begin
                valid_bit[i] <= 0;
            end
        end else begin
            case (state)
                IDLE: begin
                    ready_out <= 0;
                    if (valid_in) begin
                        state <= COMPARE;
                    end
                end
                COMPARE: begin
                    // Check for hit
                    if (valid_bit[index] && cache_tag[index] == tag) begin
                        // Cache Hit
                        data_out <= cache_data[index];
                        ready_out <= 1;
                        state <= IDLE;
                    end else begin
                        // Cache Miss
                        mem_read_valid <= 1;
                        mem_read_address <= addr_in;
                        state <= ALLOCATE;
                    end
                end
                ALLOCATE: begin
                    if (mem_read_ready) begin
                        // Memory returned data
                        mem_read_valid <= 0;
                        
                        // Update cache
                        cache_data[index] <= mem_read_data;
                        cache_tag[index] <= tag;
                        valid_bit[index] <= 1;

                        // Return data to CPU
                        data_out <= mem_read_data;
                        ready_out <= 1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
