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
// Designer   : Multi-Channel Convolution + DMA Testbench
//
// Description:
//  Combined testbench for multi-channel 2D convolution accelerator 
//  with DMA integration.
//
//  Tests:
//  1. Register read/write verification
//  2. 16x16x3 input with 3x3x3 kernel producing 14x14x3 output
//  3. DMA transfer of results to memory
//  4. Software reference comparison
//
//  Parameters:
//  - Input: 16×16×3 (width×height×channels)
//  - Kernel: 3×3×3
//  - Output: 14×14×3
//  - Data width: 32-bit per element
//  - Stride: 1
//  - Padding: Invalid (none)
//
// ====================================================================

`timescale 1ns/1ps

module tb_conv2d_dma();

  //////////////////////////////////////////////////////////////
  // Parameters
  //////////////////////////////////////////////////////////////
  localparam INPUT_WIDTH   = 16;
  localparam INPUT_HEIGHT  = 16;
  localparam NUM_CHANNELS  = 3;
  localparam KERNEL_SIZE   = 3;
  localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 14
  localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 14

  // Memory addresses
  localparam FEATURE_MAP_BASE = 32'h0000_0000;
  localparam KERNEL_BASE      = 32'h0000_1000;
  localparam OUTPUT_BASE      = 32'h0000_2000;
  localparam DMA_DST_BASE     = 32'h0000_3000;

  //////////////////////////////////////////////////////////////
  // Clock and Reset
  //////////////////////////////////////////////////////////////
  reg clk;
  reg rst_n;

  initial begin
    clk = 0;
    forever #5 clk = ~clk;  // 100MHz clock
  end

  initial begin
    rst_n = 0;
    #100 rst_n = 1;
  end

  //////////////////////////////////////////////////////////////
  // Convolution DUT Signals
  //////////////////////////////////////////////////////////////
  reg                  conv_cfg_icb_cmd_valid;
  wire                 conv_cfg_icb_cmd_ready;
  reg  [31:0]          conv_cfg_icb_cmd_addr;
  reg                  conv_cfg_icb_cmd_read;
  reg  [31:0]          conv_cfg_icb_cmd_wdata;
  reg  [3:0]           conv_cfg_icb_cmd_wmask;
  
  wire                 conv_cfg_icb_rsp_valid;
  reg                  conv_cfg_icb_rsp_ready;
  wire                 conv_cfg_icb_rsp_err;
  wire [31:0]          conv_cfg_icb_rsp_rdata;

  wire                 conv_mst_icb_cmd_valid;
  reg                  conv_mst_icb_cmd_ready;
  wire [31:0]          conv_mst_icb_cmd_addr;
  wire                 conv_mst_icb_cmd_read;
  wire [31:0]          conv_mst_icb_cmd_wdata;
  wire [3:0]           conv_mst_icb_cmd_wmask;

  reg                  conv_mst_icb_rsp_valid;
  wire                 conv_mst_icb_rsp_ready;
  reg                  conv_mst_icb_rsp_err;
  reg  [31:0]          conv_mst_icb_rsp_rdata;

  wire                 conv_irq;

  //////////////////////////////////////////////////////////////
  // DMA DUT Signals
  //////////////////////////////////////////////////////////////
  reg                  dma_cfg_icb_cmd_valid;
  wire                 dma_cfg_icb_cmd_ready;
  reg  [31:0]          dma_cfg_icb_cmd_addr;
  reg                  dma_cfg_icb_cmd_read;
  reg  [31:0]          dma_cfg_icb_cmd_wdata;
  reg  [3:0]           dma_cfg_icb_cmd_wmask;
  
  wire                 dma_cfg_icb_rsp_valid;
  reg                  dma_cfg_icb_rsp_ready;
  wire                 dma_cfg_icb_rsp_err;
  wire [31:0]          dma_cfg_icb_rsp_rdata;

  wire                 dma_mst_icb_cmd_valid;
  reg                  dma_mst_icb_cmd_ready;
  wire [31:0]          dma_mst_icb_cmd_addr;
  wire                 dma_mst_icb_cmd_read;
  wire [31:0]          dma_mst_icb_cmd_wdata;
  wire [3:0]           dma_mst_icb_cmd_wmask;

  reg                  dma_mst_icb_rsp_valid;
  wire                 dma_mst_icb_rsp_ready;
  reg                  dma_mst_icb_rsp_err;
  reg  [31:0]          dma_mst_icb_rsp_rdata;

  wire                 dma_irq;

  //////////////////////////////////////////////////////////////
  // DUT Instances
  //////////////////////////////////////////////////////////////
  sirv_conv2d_multichan u_conv (
    .clk                (clk),
    .rst_n              (rst_n),
    .conv_irq           (conv_irq),
    .cfg_icb_cmd_valid  (conv_cfg_icb_cmd_valid),
    .cfg_icb_cmd_ready  (conv_cfg_icb_cmd_ready),
    .cfg_icb_cmd_addr   (conv_cfg_icb_cmd_addr),
    .cfg_icb_cmd_read   (conv_cfg_icb_cmd_read),
    .cfg_icb_cmd_wdata  (conv_cfg_icb_cmd_wdata),
    .cfg_icb_cmd_wmask  (conv_cfg_icb_cmd_wmask),
    .cfg_icb_rsp_valid  (conv_cfg_icb_rsp_valid),
    .cfg_icb_rsp_ready  (conv_cfg_icb_rsp_ready),
    .cfg_icb_rsp_err    (conv_cfg_icb_rsp_err),
    .cfg_icb_rsp_rdata  (conv_cfg_icb_rsp_rdata),
    .mst_icb_cmd_valid  (conv_mst_icb_cmd_valid),
    .mst_icb_cmd_ready  (conv_mst_icb_cmd_ready),
    .mst_icb_cmd_addr   (conv_mst_icb_cmd_addr),
    .mst_icb_cmd_read   (conv_mst_icb_cmd_read),
    .mst_icb_cmd_wdata  (conv_mst_icb_cmd_wdata),
    .mst_icb_cmd_wmask  (conv_mst_icb_cmd_wmask),
    .mst_icb_rsp_valid  (conv_mst_icb_rsp_valid),
    .mst_icb_rsp_ready  (conv_mst_icb_rsp_ready),
    .mst_icb_rsp_err    (conv_mst_icb_rsp_err),
    .mst_icb_rsp_rdata  (conv_mst_icb_rsp_rdata)
  );

  sirv_dma_ctrl u_dma (
    .clk                (clk),
    .rst_n              (rst_n),
    .dma_irq            (dma_irq),
    .cfg_icb_cmd_valid  (dma_cfg_icb_cmd_valid),
    .cfg_icb_cmd_ready  (dma_cfg_icb_cmd_ready),
    .cfg_icb_cmd_addr   (dma_cfg_icb_cmd_addr),
    .cfg_icb_cmd_read   (dma_cfg_icb_cmd_read),
    .cfg_icb_cmd_wdata  (dma_cfg_icb_cmd_wdata),
    .cfg_icb_cmd_wmask  (dma_cfg_icb_cmd_wmask),
    .cfg_icb_rsp_valid  (dma_cfg_icb_rsp_valid),
    .cfg_icb_rsp_ready  (dma_cfg_icb_rsp_ready),
    .cfg_icb_rsp_err    (dma_cfg_icb_rsp_err),
    .cfg_icb_rsp_rdata  (dma_cfg_icb_rsp_rdata),
    .mst_icb_cmd_valid  (dma_mst_icb_cmd_valid),
    .mst_icb_cmd_ready  (dma_mst_icb_cmd_ready),
    .mst_icb_cmd_addr   (dma_mst_icb_cmd_addr),
    .mst_icb_cmd_read   (dma_mst_icb_cmd_read),
    .mst_icb_cmd_wdata  (dma_mst_icb_cmd_wdata),
    .mst_icb_cmd_wmask  (dma_mst_icb_cmd_wmask),
    .mst_icb_rsp_valid  (dma_mst_icb_rsp_valid),
    .mst_icb_rsp_ready  (dma_mst_icb_rsp_ready),
    .mst_icb_rsp_err    (dma_mst_icb_rsp_err),
    .mst_icb_rsp_rdata  (dma_mst_icb_rsp_rdata)
  );

  //////////////////////////////////////////////////////////////
  // Memory Model - Shared memory for both modules
  //////////////////////////////////////////////////////////////
  reg [31:0] memory [0:16383];  // 64KB memory (32-bit words)
  integer init_i, init_j, init_c;

  // Initialize memory with test data
  initial begin
    // Initialize all memory to 0
    for (init_i = 0; init_i < 16384; init_i = init_i + 1) begin
      memory[init_i] = 32'h0;
    end
    
    // Initialize feature map: 16x16x3 with simple pattern
    // Each channel has values: channel*1000 + row*16 + col
    for (init_c = 0; init_c < NUM_CHANNELS; init_c = init_c + 1) begin
      for (init_i = 0; init_i < INPUT_HEIGHT; init_i = init_i + 1) begin
        for (init_j = 0; init_j < INPUT_WIDTH; init_j = init_j + 1) begin
          memory[(FEATURE_MAP_BASE >> 2) + init_c * INPUT_HEIGHT * INPUT_WIDTH + init_i * INPUT_WIDTH + init_j] = 
            init_c * 1000 + init_i * 16 + init_j;
        end
      end
    end
    
    // Initialize kernels: 3x3x3 identity-like kernels (center = 1, others = 0)
    // Kernel for each channel
    for (init_c = 0; init_c < NUM_CHANNELS; init_c = init_c + 1) begin
      for (init_i = 0; init_i < 9; init_i = init_i + 1) begin
        if (init_i == 4) begin  // Center element
          memory[(KERNEL_BASE >> 2) + init_c * 9 + init_i] = 32'd1;
        end else begin
          memory[(KERNEL_BASE >> 2) + init_c * 9 + init_i] = 32'd0;
        end
      end
    end
  end

  //////////////////////////////////////////////////////////////
  // Memory Interface for Convolution Module
  //////////////////////////////////////////////////////////////
  reg [2:0] conv_mem_state;
  localparam CONV_MEM_IDLE = 3'd0;
  localparam CONV_MEM_READ_RSP = 3'd1;
  localparam CONV_MEM_WRITE_RSP = 3'd2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_mem_state <= CONV_MEM_IDLE;
      conv_mst_icb_rsp_valid <= 1'b0;
      conv_mst_icb_rsp_err <= 1'b0;
      conv_mst_icb_rsp_rdata <= 32'h0;
      conv_mst_icb_cmd_ready <= 1'b1;
    end else begin
      case (conv_mem_state)
        CONV_MEM_IDLE: begin
          if (conv_mst_icb_cmd_valid && conv_mst_icb_cmd_ready) begin
            if (conv_mst_icb_cmd_read) begin
              conv_mem_state <= CONV_MEM_READ_RSP;
              conv_mst_icb_rsp_rdata <= memory[conv_mst_icb_cmd_addr >> 2];
              conv_mst_icb_rsp_valid <= 1'b1;
            end else begin
              memory[conv_mst_icb_cmd_addr >> 2] <= conv_mst_icb_cmd_wdata;
              conv_mem_state <= CONV_MEM_WRITE_RSP;
              conv_mst_icb_rsp_valid <= 1'b1;
            end
            conv_mst_icb_cmd_ready <= 1'b0;
          end
        end

        CONV_MEM_READ_RSP: begin
          if (conv_mst_icb_rsp_ready) begin
            conv_mst_icb_rsp_valid <= 1'b0;
            conv_mst_icb_cmd_ready <= 1'b1;
            conv_mem_state <= CONV_MEM_IDLE;
          end
        end

        CONV_MEM_WRITE_RSP: begin
          if (conv_mst_icb_rsp_ready) begin
            conv_mst_icb_rsp_valid <= 1'b0;
            conv_mst_icb_cmd_ready <= 1'b1;
            conv_mem_state <= CONV_MEM_IDLE;
          end
        end

        default: conv_mem_state <= CONV_MEM_IDLE;
      endcase
    end
  end

  //////////////////////////////////////////////////////////////
  // Memory Interface for DMA Module
  //////////////////////////////////////////////////////////////
  reg [2:0] dma_mem_state;
  localparam DMA_MEM_IDLE = 3'd0;
  localparam DMA_MEM_READ_RSP = 3'd1;
  localparam DMA_MEM_WRITE_RSP = 3'd2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_mem_state <= DMA_MEM_IDLE;
      dma_mst_icb_rsp_valid <= 1'b0;
      dma_mst_icb_rsp_err <= 1'b0;
      dma_mst_icb_rsp_rdata <= 32'h0;
      dma_mst_icb_cmd_ready <= 1'b1;
    end else begin
      case (dma_mem_state)
        DMA_MEM_IDLE: begin
          if (dma_mst_icb_cmd_valid && dma_mst_icb_cmd_ready) begin
            if (dma_mst_icb_cmd_read) begin
              dma_mem_state <= DMA_MEM_READ_RSP;
              dma_mst_icb_rsp_rdata <= memory[dma_mst_icb_cmd_addr >> 2];
              dma_mst_icb_rsp_valid <= 1'b1;
            end else begin
              memory[dma_mst_icb_cmd_addr >> 2] <= dma_mst_icb_cmd_wdata;
              dma_mem_state <= DMA_MEM_WRITE_RSP;
              dma_mst_icb_rsp_valid <= 1'b1;
            end
            dma_mst_icb_cmd_ready <= 1'b0;
          end
        end

        DMA_MEM_READ_RSP: begin
          if (dma_mst_icb_rsp_ready) begin
            dma_mst_icb_rsp_valid <= 1'b0;
            dma_mst_icb_cmd_ready <= 1'b1;
            dma_mem_state <= DMA_MEM_IDLE;
          end
        end

        DMA_MEM_WRITE_RSP: begin
          if (dma_mst_icb_rsp_ready) begin
            dma_mst_icb_rsp_valid <= 1'b0;
            dma_mst_icb_cmd_ready <= 1'b1;
            dma_mem_state <= DMA_MEM_IDLE;
          end
        end

        default: dma_mem_state <= DMA_MEM_IDLE;
      endcase
    end
  end

  //////////////////////////////////////////////////////////////
  // Test Tasks
  //////////////////////////////////////////////////////////////
  task conv_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      conv_cfg_icb_cmd_valid <= 1'b1;
      conv_cfg_icb_cmd_addr <= addr;
      conv_cfg_icb_cmd_read <= 1'b0;
      conv_cfg_icb_cmd_wdata <= data;
      conv_cfg_icb_cmd_wmask <= 4'hF;
      @(posedge clk);
      while (!conv_cfg_icb_cmd_ready) @(posedge clk);
      conv_cfg_icb_cmd_valid <= 1'b0;
      while (!conv_cfg_icb_rsp_valid) @(posedge clk);
      @(posedge clk);
    end
  endtask

  task conv_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      conv_cfg_icb_cmd_valid <= 1'b1;
      conv_cfg_icb_cmd_addr <= addr;
      conv_cfg_icb_cmd_read <= 1'b1;
      conv_cfg_icb_cmd_wdata <= 32'h0;
      conv_cfg_icb_cmd_wmask <= 4'h0;
      @(posedge clk);
      while (!conv_cfg_icb_cmd_ready) @(posedge clk);
      conv_cfg_icb_cmd_valid <= 1'b0;
      while (!conv_cfg_icb_rsp_valid) @(posedge clk);
      data = conv_cfg_icb_rsp_rdata;
      @(posedge clk);
    end
  endtask

  task dma_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      dma_cfg_icb_cmd_valid <= 1'b1;
      dma_cfg_icb_cmd_addr <= addr;
      dma_cfg_icb_cmd_read <= 1'b0;
      dma_cfg_icb_cmd_wdata <= data;
      dma_cfg_icb_cmd_wmask <= 4'hF;
      @(posedge clk);
      while (!dma_cfg_icb_cmd_ready) @(posedge clk);
      dma_cfg_icb_cmd_valid <= 1'b0;
      while (!dma_cfg_icb_rsp_valid) @(posedge clk);
      @(posedge clk);
    end
  endtask

  task dma_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      dma_cfg_icb_cmd_valid <= 1'b1;
      dma_cfg_icb_cmd_addr <= addr;
      dma_cfg_icb_cmd_read <= 1'b1;
      dma_cfg_icb_cmd_wdata <= 32'h0;
      dma_cfg_icb_cmd_wmask <= 4'h0;
      @(posedge clk);
      while (!dma_cfg_icb_cmd_ready) @(posedge clk);
      dma_cfg_icb_cmd_valid <= 1'b0;
      while (!dma_cfg_icb_rsp_valid) @(posedge clk);
      data = dma_cfg_icb_rsp_rdata;
      @(posedge clk);
    end
  endtask

  //////////////////////////////////////////////////////////////
  // Test Sequence
  //////////////////////////////////////////////////////////////
  reg [31:0] read_data;
  integer test_pass;
  integer errors;
  integer verify_c, verify_y, verify_x;
  reg [31:0] expected_value;
  reg [31:0] actual_value;

  // Register offsets
  localparam CONV_CTRL_OFFSET       = 8'h00;
  localparam CONV_SRC_ADDR_OFFSET   = 8'h04;
  localparam CONV_DST_ADDR_OFFSET   = 8'h08;
  localparam CONV_IMG_WIDTH_OFFSET  = 8'h0C;
  localparam CONV_IMG_HEIGHT_OFFSET = 8'h10;
  localparam CONV_CHANNELS_OFFSET   = 8'h14;
  localparam CONV_KERNEL_OFFSET     = 8'h18;
  localparam CONV_STATUS_OFFSET     = 8'h1C;

  localparam DMA_CTRL_OFFSET        = 8'h00;
  localparam DMA_SRC_ADDR_OFFSET    = 8'h04;
  localparam DMA_DST_ADDR_OFFSET    = 8'h08;
  localparam DMA_XFER_LEN_OFFSET    = 8'h0C;
  localparam DMA_STATUS_OFFSET      = 8'h10;

  initial begin
    // Initialize signals
    conv_cfg_icb_cmd_valid = 1'b0;
    conv_cfg_icb_cmd_addr = 32'h0;
    conv_cfg_icb_cmd_read = 1'b0;
    conv_cfg_icb_cmd_wdata = 32'h0;
    conv_cfg_icb_cmd_wmask = 4'h0;
    conv_cfg_icb_rsp_ready = 1'b1;

    dma_cfg_icb_cmd_valid = 1'b0;
    dma_cfg_icb_cmd_addr = 32'h0;
    dma_cfg_icb_cmd_read = 1'b0;
    dma_cfg_icb_cmd_wdata = 32'h0;
    dma_cfg_icb_cmd_wmask = 4'h0;
    dma_cfg_icb_rsp_ready = 1'b1;

    test_pass = 1;
    errors = 0;

    // Wait for reset
    @(posedge rst_n);
    repeat(10) @(posedge clk);

    $display("========================================");
    $display("Multi-Channel Conv2D + DMA Testbench");
    $display("========================================");
    $display("Input:  %0dx%0dx%0d", INPUT_WIDTH, INPUT_HEIGHT, NUM_CHANNELS);
    $display("Kernel: %0dx%0dx%0d", KERNEL_SIZE, KERNEL_SIZE, NUM_CHANNELS);
    $display("Output: %0dx%0dx%0d", OUTPUT_WIDTH, OUTPUT_HEIGHT, NUM_CHANNELS);
    $display("Data width: 32-bit");
    $display("Stride: 1, Padding: None");

    //////////////////////////////////////////////////////////////
    // Test 1: Register Read/Write
    //////////////////////////////////////////////////////////////
    $display("\n--- Test 1: Register Read/Write ---");
    
    conv_write(CONV_SRC_ADDR_OFFSET, FEATURE_MAP_BASE);
    conv_read(CONV_SRC_ADDR_OFFSET, read_data);
    if (read_data != FEATURE_MAP_BASE) begin
      $display("ERROR: Source address mismatch");
      test_pass = 0;
    end else begin
      $display("PASS: Source address = 0x%08h", read_data);
    end

    conv_write(CONV_DST_ADDR_OFFSET, OUTPUT_BASE);
    conv_read(CONV_DST_ADDR_OFFSET, read_data);
    if (read_data != OUTPUT_BASE) begin
      $display("ERROR: Destination address mismatch");
      test_pass = 0;
    end else begin
      $display("PASS: Destination address = 0x%08h", read_data);
    end

    conv_write(CONV_KERNEL_OFFSET, KERNEL_BASE);
    conv_read(CONV_KERNEL_OFFSET, read_data);
    if (read_data != KERNEL_BASE) begin
      $display("ERROR: Kernel address mismatch");
      test_pass = 0;
    end else begin
      $display("PASS: Kernel address = 0x%08h", read_data);
    end

    //////////////////////////////////////////////////////////////
    // Test 2: Multi-Channel Convolution
    //////////////////////////////////////////////////////////////
    $display("\n--- Test 2: Multi-Channel Convolution (16x16x3 -> 14x14x3) ---");
    
    // Configure convolution
    conv_write(CONV_IMG_WIDTH_OFFSET, INPUT_WIDTH);
    conv_write(CONV_IMG_HEIGHT_OFFSET, INPUT_HEIGHT);
    conv_write(CONV_CHANNELS_OFFSET, NUM_CHANNELS);
    
    // Start convolution
    $display("Starting convolution...");
    conv_write(CONV_CTRL_OFFSET, 32'h0000_0003);  // Enable + Start

    // Wait for completion
    read_data = 32'h0;
    while ((read_data & 32'h4) == 0) begin
      conv_read(CONV_CTRL_OFFSET, read_data);
      repeat(100) @(posedge clk);
    end
    $display("Convolution complete!");

    // Verify results - with identity kernel, output should equal center of input window
    $display("Verifying convolution results...");
    errors = 0;
    for (verify_c = 0; verify_c < NUM_CHANNELS; verify_c = verify_c + 1) begin
      for (verify_y = 0; verify_y < OUTPUT_HEIGHT; verify_y = verify_y + 1) begin
        for (verify_x = 0; verify_x < OUTPUT_WIDTH; verify_x = verify_x + 1) begin
          // Expected: input[c][y+1][x+1] (center of 3x3 window)
          expected_value = verify_c * 1000 + (verify_y + 1) * 16 + (verify_x + 1);
          actual_value = memory[(OUTPUT_BASE >> 2) + verify_c * OUTPUT_HEIGHT * OUTPUT_WIDTH + verify_y * OUTPUT_WIDTH + verify_x];
          
          if (expected_value != actual_value) begin
            errors = errors + 1;
            if (errors <= 5) begin  // Only show first 5 errors
              $display("ERROR at [%0d][%0d][%0d]: expected %0d, got %0d", 
                       verify_c, verify_y, verify_x, expected_value, actual_value);
            end
          end
        end
      end
    end
    
    if (errors == 0) begin
      $display("PASS: All %0d output values verified correctly!", 
               NUM_CHANNELS * OUTPUT_HEIGHT * OUTPUT_WIDTH);
    end else begin
      $display("FAIL: %0d errors found in convolution output", errors);
      test_pass = 0;
    end

    // Show sample output values
    $display("Sample outputs:");
    $display("  output[0][0][0] = %0d (expected %0d)", 
             memory[(OUTPUT_BASE >> 2) + 0], 0*1000 + 1*16 + 1);
    $display("  output[0][6][6] = %0d (expected %0d)", 
             memory[(OUTPUT_BASE >> 2) + 6*OUTPUT_WIDTH + 6], 0*1000 + 7*16 + 7);
    $display("  output[1][0][0] = %0d (expected %0d)", 
             memory[(OUTPUT_BASE >> 2) + 1*OUTPUT_HEIGHT*OUTPUT_WIDTH], 1*1000 + 1*16 + 1);
    $display("  output[2][13][13] = %0d (expected %0d)", 
             memory[(OUTPUT_BASE >> 2) + 2*OUTPUT_HEIGHT*OUTPUT_WIDTH + 13*OUTPUT_WIDTH + 13], 
             2*1000 + 14*16 + 14);

    // Clear done flag
    conv_write(CONV_CTRL_OFFSET, 32'h0000_0005);

    //////////////////////////////////////////////////////////////
    // Test 3: DMA Transfer of Results
    //////////////////////////////////////////////////////////////
    $display("\n--- Test 3: DMA Transfer of Convolution Results ---");
    
    // Configure DMA to copy convolution output to another location
    dma_write(DMA_SRC_ADDR_OFFSET, OUTPUT_BASE);
    dma_write(DMA_DST_ADDR_OFFSET, DMA_DST_BASE);
    dma_write(DMA_XFER_LEN_OFFSET, NUM_CHANNELS * OUTPUT_HEIGHT * OUTPUT_WIDTH * 4);  // Total bytes
    
    // Start DMA
    $display("Starting DMA transfer (%0d bytes)...", NUM_CHANNELS * OUTPUT_HEIGHT * OUTPUT_WIDTH * 4);
    dma_write(DMA_CTRL_OFFSET, 32'h0000_0003);  // Enable + Start

    // Wait for DMA completion
    read_data = 32'h0;
    while ((read_data & 32'h4) == 0) begin
      dma_read(DMA_CTRL_OFFSET, read_data);
      repeat(100) @(posedge clk);
    end
    $display("DMA transfer complete!");

    // Verify DMA transfer
    $display("Verifying DMA transfer...");
    errors = 0;
    for (verify_c = 0; verify_c < NUM_CHANNELS; verify_c = verify_c + 1) begin
      for (verify_y = 0; verify_y < OUTPUT_HEIGHT; verify_y = verify_y + 1) begin
        for (verify_x = 0; verify_x < OUTPUT_WIDTH; verify_x = verify_x + 1) begin
          expected_value = memory[(OUTPUT_BASE >> 2) + verify_c * OUTPUT_HEIGHT * OUTPUT_WIDTH + verify_y * OUTPUT_WIDTH + verify_x];
          actual_value = memory[(DMA_DST_BASE >> 2) + verify_c * OUTPUT_HEIGHT * OUTPUT_WIDTH + verify_y * OUTPUT_WIDTH + verify_x];
          
          if (expected_value != actual_value) begin
            errors = errors + 1;
            if (errors <= 5) begin
              $display("ERROR at DMA[%0d][%0d][%0d]: expected %0d, got %0d", 
                       verify_c, verify_y, verify_x, expected_value, actual_value);
            end
          end
        end
      end
    end
    
    if (errors == 0) begin
      $display("PASS: DMA transferred all %0d values correctly!", 
               NUM_CHANNELS * OUTPUT_HEIGHT * OUTPUT_WIDTH);
    end else begin
      $display("FAIL: %0d errors in DMA transfer", errors);
      test_pass = 0;
    end

    // Clear DMA done flag
    dma_write(DMA_CTRL_OFFSET, 32'h0000_0005);

    //////////////////////////////////////////////////////////////
    // Test Summary
    //////////////////////////////////////////////////////////////
    repeat(10) @(posedge clk);
    $display("\n========================================");
    if (test_pass) begin
      $display("ALL TESTS PASSED");
    end else begin
      $display("SOME TESTS FAILED");
    end
    $display("========================================\n");
    
    $finish;
  end

  //////////////////////////////////////////////////////////////
  // Waveform dump
  //////////////////////////////////////////////////////////////
  initial begin
    $dumpfile("tb_conv2d_dma.vcd");
    $dumpvars(0, tb_conv2d_dma);
  end

  // Timeout
  initial begin
    #50000000  // 500ms timeout (50M * 10ns = 500ms with 100MHz clock)
    $display("ERROR: Test timeout!");
    $finish;
  end

endmodule
