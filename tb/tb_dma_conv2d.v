/*                                                                      
Copyright 2018-2020 Nuclei System Technology, Inc.                
                                                                        
Licensed under the Apache License, Version 2.0 (the "License");         
you may not use this file except in compliance with the License.        
You may obtain a copy of the License at                                 
                                                                        
    http://www.apache.org/licenses/LICENSE-2.0                          
                                                                        
 Unless required by applicable law or agreed to in writing, software    
distributed under the License is distributed on an "AS IS" BASIS,       
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and     
limitations under the License.                                          
*/                                                                      
                                                                        
//=====================================================================
//
// Description:
//  Testbench for DMA controller with 2D convolution demonstration
//  This testbench:
//  1. Generates test input data (simulated image)
//  2. Performs simple 3x3 convolution in procedural code
//  3. Uses DMA to transfer convolution results
//  4. Verifies the DMA transfer
//
// ====================================================================

`timescale 1ns/1ps

module tb_dma_conv2d;

    // Clock and reset
    reg         clk;
    reg         rst_n;
    
    // APB interface
    reg         psel;
    reg         penable;
    reg         pwrite;
    reg  [11:0] paddr;
    reg  [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready;
    wire        pslverr;
    
    // DMA memory interface
    wire        dma_cmd_valid;
    reg         dma_cmd_ready;
    wire [31:0] dma_cmd_addr;
    wire        dma_cmd_read;
    wire [31:0] dma_cmd_wdata;
    wire [3:0]  dma_cmd_wmask;
    
    reg         dma_rsp_valid;
    wire        dma_rsp_ready;
    reg         dma_rsp_err;
    reg  [31:0] dma_rsp_rdata;
    
    wire        dma_irq;
    
    // Register addresses
    localparam ADDR_CTRL   = 12'h000;
    localparam ADDR_SRC    = 12'h004;
    localparam ADDR_DST    = 12'h008;
    localparam ADDR_LENGTH = 12'h00C;
    localparam ADDR_STATUS = 12'h010;
    
    // Memory simulation (1KB each for source and destination)
    reg [31:0] src_memory [0:255];
    reg [31:0] dst_memory [0:255];
    
    // Convolution parameters
    localparam IMG_WIDTH  = 8;
    localparam IMG_HEIGHT = 8;
    localparam KERNEL_SIZE = 3;
    localparam OUT_WIDTH  = IMG_WIDTH - KERNEL_SIZE + 1;
    localparam OUT_HEIGHT = IMG_HEIGHT - KERNEL_SIZE + 1;
    
    // Base addresses for simulation
    localparam SRC_BASE = 32'h9000_0000;
    localparam DST_BASE = 32'h9000_1000;
    
    // Convolution kernel (Sobel X)
    reg signed [7:0] kernel [0:2][0:2];
    
    // Test variables
    integer i, j, kx, ky, idx;
    reg signed [31:0] conv_sum;
    reg signed [7:0] input_data [0:IMG_HEIGHT-1][0:IMG_WIDTH-1];
    reg signed [7:0] output_data [0:OUT_HEIGHT-1][0:OUT_WIDTH-1];
    reg [31:0] read_data;
    integer errors;
    
    // DMA under test
    sirv_dma u_dma (
        .clk           (clk),
        .rst_n         (rst_n),
        .psel          (psel),
        .penable       (penable),
        .pwrite        (pwrite),
        .paddr         (paddr),
        .pwdata        (pwdata),
        .prdata        (prdata),
        .pready        (pready),
        .pslverr       (pslverr),
        .dma_cmd_valid (dma_cmd_valid),
        .dma_cmd_ready (dma_cmd_ready),
        .dma_cmd_addr  (dma_cmd_addr),
        .dma_cmd_read  (dma_cmd_read),
        .dma_cmd_wdata (dma_cmd_wdata),
        .dma_cmd_wmask (dma_cmd_wmask),
        .dma_rsp_valid (dma_rsp_valid),
        .dma_rsp_ready (dma_rsp_ready),
        .dma_rsp_err   (dma_rsp_err),
        .dma_rsp_rdata (dma_rsp_rdata),
        .dma_irq       (dma_irq)
    );
    
    // Clock generation (10ns period = 100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Memory interface simulation
    reg [1:0] mem_state;
    localparam MEM_IDLE = 2'd0;
    localparam MEM_READ = 2'd1;
    localparam MEM_WRITE = 2'd2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_cmd_ready <= 1'b0;
            dma_rsp_valid <= 1'b0;
            dma_rsp_err   <= 1'b0;
            dma_rsp_rdata <= 32'h0;
            mem_state     <= MEM_IDLE;
        end else begin
            case (mem_state)
                MEM_IDLE: begin
                    dma_rsp_valid <= 1'b0;
                    if (dma_cmd_valid) begin
                        dma_cmd_ready <= 1'b1;
                        if (dma_cmd_read) begin
                            mem_state <= MEM_READ;
                        end else begin
                            mem_state <= MEM_WRITE;
                        end
                    end else begin
                        dma_cmd_ready <= 1'b0;
                    end
                end
                
                MEM_READ: begin
                    dma_cmd_ready <= 1'b0;
                    // Simulate 1 cycle memory read latency
                    if (dma_cmd_addr >= SRC_BASE && dma_cmd_addr < SRC_BASE + 32'h1000) begin
                        dma_rsp_rdata <= src_memory[(dma_cmd_addr - SRC_BASE) >> 2];
                    end else begin
                        dma_rsp_rdata <= 32'hDEADBEEF;
                    end
                    dma_rsp_valid <= 1'b1;
                    dma_rsp_err   <= 1'b0;
                    mem_state <= MEM_IDLE;
                end
                
                MEM_WRITE: begin
                    dma_cmd_ready <= 1'b0;
                    // Simulate 1 cycle memory write latency
                    if (dma_cmd_addr >= DST_BASE && dma_cmd_addr < DST_BASE + 32'h1000) begin
                        dst_memory[(dma_cmd_addr - DST_BASE) >> 2] <= dma_cmd_wdata;
                    end
                    dma_rsp_valid <= 1'b1;
                    dma_rsp_err   <= 1'b0;
                    mem_state <= MEM_IDLE;
                end
                
                default: mem_state <= MEM_IDLE;
            endcase
        end
    end
    
    // APB Write task
    task apb_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel    = 1'b1;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            @(posedge clk);
            penable = 1'b1;
            @(posedge clk);
            while (!pready) @(posedge clk);
            psel    = 1'b0;
            penable = 1'b0;
            pwrite  = 1'b0;
        end
    endtask
    
    // APB Read task
    task apb_read;
        input  [11:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            psel    = 1'b1;
            pwrite  = 1'b0;
            paddr   = addr;
            @(posedge clk);
            penable = 1'b1;
            @(posedge clk);
            while (!pready) @(posedge clk);
            data    = prdata;
            psel    = 1'b0;
            penable = 1'b0;
        end
    endtask
    
    // Wait for DMA completion
    task wait_dma_done;
        reg [31:0] status;
        begin
            status = 32'h0;
            while (!(status[1])) begin  // Wait for done bit
                apb_read(ADDR_STATUS, status);
            end
        end
    endtask
    
    // Main test sequence
    initial begin
        // Initialize signals
        rst_n   = 0;
        psel    = 0;
        penable = 0;
        pwrite  = 0;
        paddr   = 0;
        pwdata  = 0;
        errors  = 0;
        
        // Initialize kernel (Sobel X edge detector)
        kernel[0][0] = -8'd1; kernel[0][1] = 8'd0; kernel[0][2] = 8'd1;
        kernel[1][0] = -8'd2; kernel[1][1] = 8'd0; kernel[1][2] = 8'd2;
        kernel[2][0] = -8'd1; kernel[2][1] = 8'd0; kernel[2][2] = 8'd1;
        
        // Generate test input data (simple gradient pattern)
        $display("==============================================");
        $display("Generating input data (8x8 gradient pattern)");
        $display("==============================================");
        for (i = 0; i < IMG_HEIGHT; i = i + 1) begin
            for (j = 0; j < IMG_WIDTH; j = j + 1) begin
                input_data[i][j] = i * IMG_WIDTH + j;  // Simple gradient
            end
        end
        
        // Perform 2D convolution in software
        $display("\n==============================================");
        $display("Performing 3x3 convolution (Sobel X)");
        $display("==============================================");
        for (i = 0; i < OUT_HEIGHT; i = i + 1) begin
            for (j = 0; j < OUT_WIDTH; j = j + 1) begin
                conv_sum = 0;
                for (ky = 0; ky < KERNEL_SIZE; ky = ky + 1) begin
                    for (kx = 0; kx < KERNEL_SIZE; kx = kx + 1) begin
                        conv_sum = conv_sum + input_data[i+ky][j+kx] * kernel[ky][kx];
                    end
                end
                // Saturate to int8 range
                if (conv_sum > 127) conv_sum = 127;
                if (conv_sum < -128) conv_sum = -128;
                output_data[i][j] = conv_sum[7:0];
            end
        end
        
        // Pack convolution output into source memory (4 bytes per word)
        $display("\n==============================================");
        $display("Packing convolution results to source memory");
        $display("==============================================");
        for (i = 0; i < 256; i = i + 1) begin
            src_memory[i] = 32'h0;
            dst_memory[i] = 32'h0;
        end
        
        for (i = 0; i < OUT_HEIGHT; i = i + 1) begin
            for (j = 0; j < OUT_WIDTH; j = j + 1) begin
                // Calculate linear index
                idx = i * OUT_WIDTH + j;
                // Pack into 32-bit words (4 bytes each)
                // Byte position within word: idx[1:0]
                // Word index: idx >> 2
                case (idx[1:0])
                    2'b00: src_memory[idx >> 2][7:0]   = output_data[i][j];
                    2'b01: src_memory[idx >> 2][15:8]  = output_data[i][j];
                    2'b10: src_memory[idx >> 2][23:16] = output_data[i][j];
                    2'b11: src_memory[idx >> 2][31:24] = output_data[i][j];
                endcase
            end
        end
        
        // Display some source memory content
        $display("Source memory content (first 4 words):");
        for (i = 0; i < 4; i = i + 1) begin
            $display("  src_memory[%0d] = 0x%08h", i, src_memory[i]);
        end
        
        // Apply reset
        $display("\n==============================================");
        $display("Applying reset");
        $display("==============================================");
        #100;
        rst_n = 1;
        #100;
        
        // Configure DMA transfer
        $display("\n==============================================");
        $display("Configuring DMA transfer");
        $display("==============================================");
        $display("  Source address: 0x%08h", SRC_BASE);
        $display("  Destination address: 0x%08h", DST_BASE);
        $display("  Transfer length: %0d words", (OUT_WIDTH * OUT_HEIGHT + 3) / 4);
        
        // Set source address
        apb_write(ADDR_SRC, SRC_BASE);
        
        // Set destination address
        apb_write(ADDR_DST, DST_BASE);
        
        // Set transfer length (in 32-bit words)
        // OUT_WIDTH * OUT_HEIGHT = 6 * 6 = 36 bytes = 9 words
        apb_write(ADDR_LENGTH, (OUT_WIDTH * OUT_HEIGHT + 3) / 4);
        
        // Read back configuration
        apb_read(ADDR_SRC, read_data);
        $display("  Read back SRC: 0x%08h", read_data);
        apb_read(ADDR_DST, read_data);
        $display("  Read back DST: 0x%08h", read_data);
        apb_read(ADDR_LENGTH, read_data);
        $display("  Read back LENGTH: %0d", read_data);
        
        // Start DMA transfer
        $display("\n==============================================");
        $display("Starting DMA transfer");
        $display("==============================================");
        apb_write(ADDR_CTRL, 32'h00000001);  // Set start bit
        
        // Wait for completion
        wait_dma_done();
        
        // Read final status
        apb_read(ADDR_STATUS, read_data);
        $display("DMA Status: 0x%08h", read_data);
        if (read_data[2]) begin
            $display("ERROR: DMA transfer error!");
            errors = errors + 1;
        end else begin
            $display("DMA transfer completed successfully");
        end
        
        // Verify transferred data
        $display("\n==============================================");
        $display("Verifying transferred data");
        $display("==============================================");
        for (i = 0; i < (OUT_WIDTH * OUT_HEIGHT + 3) / 4; i = i + 1) begin
            if (src_memory[i] != dst_memory[i]) begin
                $display("ERROR: Mismatch at word %0d: src=0x%08h, dst=0x%08h", 
                         i, src_memory[i], dst_memory[i]);
                errors = errors + 1;
            end else begin
                $display("PASS: Word %0d: 0x%08h", i, dst_memory[i]);
            end
        end
        
        // Summary
        $display("\n==============================================");
        $display("Test Summary");
        $display("==============================================");
        if (errors == 0) begin
            $display("ALL TESTS PASSED!");
            $display("2D Convolution + DMA transfer verified successfully");
        end else begin
            $display("TEST FAILED with %0d errors", errors);
        end
        $display("==============================================\n");
        
        #100;
        $finish;
    end
    
    // Timeout
    initial begin
        #100000;
        $display("ERROR: Test timeout!");
        $finish;
    end
    
    // VCD dump for waveform viewing
    initial begin
        $dumpfile("tb_dma_conv2d.vcd");
        $dumpvars(0, tb_dma_conv2d);
    end

endmodule
