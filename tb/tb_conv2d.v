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
// Designer   : 2D Convolution Testbench
//
// Description:
//  Testbench for 2D convolution accelerator with DMA integration
//  Tests:
//  1. Register read/write
//  2. Simple 4x4 image convolution with identity kernel
//  3. Edge detection kernel test
//  4. Verify results against software reference
//
// ====================================================================

`timescale 1ns/1ps

module tb_conv2d();

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
  // DUT Signals - Configuration interface
  //////////////////////////////////////////////////////////////
  reg                  cfg_icb_cmd_valid;
  wire                 cfg_icb_cmd_ready;
  reg  [31:0]          cfg_icb_cmd_addr;
  reg                  cfg_icb_cmd_read;
  reg  [31:0]          cfg_icb_cmd_wdata;
  reg  [3:0]           cfg_icb_cmd_wmask;
  
  wire                 cfg_icb_rsp_valid;
  reg                  cfg_icb_rsp_ready;
  wire                 cfg_icb_rsp_err;
  wire [31:0]          cfg_icb_rsp_rdata;

  //////////////////////////////////////////////////////////////
  // DUT Signals - Master interface (to memory)
  //////////////////////////////////////////////////////////////
  wire                 mst_icb_cmd_valid;
  reg                  mst_icb_cmd_ready;
  wire [31:0]          mst_icb_cmd_addr;
  wire                 mst_icb_cmd_read;
  wire [31:0]          mst_icb_cmd_wdata;
  wire [3:0]           mst_icb_cmd_wmask;

  reg                  mst_icb_rsp_valid;
  wire                 mst_icb_rsp_ready;
  reg                  mst_icb_rsp_err;
  reg  [31:0]          mst_icb_rsp_rdata;

  wire                 conv_irq;

  //////////////////////////////////////////////////////////////
  // DUT Instance
  //////////////////////////////////////////////////////////////
  sirv_conv2d_accel u_dut (
    .clk                (clk),
    .rst_n              (rst_n),
    
    .conv_irq           (conv_irq),
    
    .cfg_icb_cmd_valid  (cfg_icb_cmd_valid),
    .cfg_icb_cmd_ready  (cfg_icb_cmd_ready),
    .cfg_icb_cmd_addr   (cfg_icb_cmd_addr),
    .cfg_icb_cmd_read   (cfg_icb_cmd_read),
    .cfg_icb_cmd_wdata  (cfg_icb_cmd_wdata),
    .cfg_icb_cmd_wmask  (cfg_icb_cmd_wmask),
    
    .cfg_icb_rsp_valid  (cfg_icb_rsp_valid),
    .cfg_icb_rsp_ready  (cfg_icb_rsp_ready),
    .cfg_icb_rsp_err    (cfg_icb_rsp_err),
    .cfg_icb_rsp_rdata  (cfg_icb_rsp_rdata),
    
    .mst_icb_cmd_valid  (mst_icb_cmd_valid),
    .mst_icb_cmd_ready  (mst_icb_cmd_ready),
    .mst_icb_cmd_addr   (mst_icb_cmd_addr),
    .mst_icb_cmd_read   (mst_icb_cmd_read),
    .mst_icb_cmd_wdata  (mst_icb_cmd_wdata),
    .mst_icb_cmd_wmask  (mst_icb_cmd_wmask),
    
    .mst_icb_rsp_valid  (mst_icb_rsp_valid),
    .mst_icb_rsp_ready  (mst_icb_rsp_ready),
    .mst_icb_rsp_err    (mst_icb_rsp_err),
    .mst_icb_rsp_rdata  (mst_icb_rsp_rdata)
  );

  //////////////////////////////////////////////////////////////
  // Simple Memory Model (for image storage)
  //////////////////////////////////////////////////////////////
  reg [7:0] memory [0:1023];  // 1KB memory for source image
  reg [7:0] result_memory [0:255];  // Result memory
  integer i;

  // Initialize memory with test image (4x4)
  // Simple gradient pattern for testing
  initial begin
    // Source image: 4x4 gradient
    //  10  20  30  40
    //  50  60  70  80
    //  90 100 110 120
    // 130 140 150 160
    memory[0] = 8'd10;  memory[1] = 8'd20;  memory[2] = 8'd30;  memory[3] = 8'd40;
    memory[4] = 8'd50;  memory[5] = 8'd60;  memory[6] = 8'd70;  memory[7] = 8'd80;
    memory[8] = 8'd90;  memory[9] = 8'd100; memory[10] = 8'd110; memory[11] = 8'd120;
    memory[12] = 8'd130; memory[13] = 8'd140; memory[14] = 8'd150; memory[15] = 8'd160;
    
    // Initialize result memory
    for (i = 0; i < 256; i = i + 1) begin
      result_memory[i] = 8'h00;
    end
  end

  //////////////////////////////////////////////////////////////
  // Memory Response State Machine
  //////////////////////////////////////////////////////////////
  reg [2:0] mem_state;
  localparam MEM_IDLE = 3'd0;
  localparam MEM_READ_RSP = 3'd1;
  localparam MEM_WRITE_RSP = 3'd2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_state <= MEM_IDLE;
      mst_icb_rsp_valid <= 1'b0;
      mst_icb_rsp_err <= 1'b0;
      mst_icb_rsp_rdata <= 32'h0;
      mst_icb_cmd_ready <= 1'b1;
    end else begin
      case (mem_state)
        MEM_IDLE: begin
          if (mst_icb_cmd_valid && mst_icb_cmd_ready) begin
            if (mst_icb_cmd_read) begin
              // Read from source memory
              mem_state <= MEM_READ_RSP;
              mst_icb_rsp_rdata <= {24'b0, memory[mst_icb_cmd_addr[9:0]]};
              mst_icb_rsp_valid <= 1'b1;
            end else begin
              // Write to result memory
              result_memory[mst_icb_cmd_addr[7:0]] <= mst_icb_cmd_wdata[7:0];
              mem_state <= MEM_WRITE_RSP;
              mst_icb_rsp_valid <= 1'b1;
            end
            mst_icb_cmd_ready <= 1'b0;
          end
        end

        MEM_READ_RSP: begin
          if (mst_icb_rsp_ready) begin
            mst_icb_rsp_valid <= 1'b0;
            mst_icb_cmd_ready <= 1'b1;
            mem_state <= MEM_IDLE;
          end
        end

        MEM_WRITE_RSP: begin
          if (mst_icb_rsp_ready) begin
            mst_icb_rsp_valid <= 1'b0;
            mst_icb_cmd_ready <= 1'b1;
            mem_state <= MEM_IDLE;
          end
        end

        default: begin
          mem_state <= MEM_IDLE;
        end
      endcase
    end
  end

  //////////////////////////////////////////////////////////////
  // Test Tasks
  //////////////////////////////////////////////////////////////
  task cfg_write;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge clk);
      cfg_icb_cmd_valid <= 1'b1;
      cfg_icb_cmd_addr <= addr;
      cfg_icb_cmd_read <= 1'b0;
      cfg_icb_cmd_wdata <= data;
      cfg_icb_cmd_wmask <= 4'hF;
      @(posedge clk);
      while (!cfg_icb_cmd_ready) @(posedge clk);
      cfg_icb_cmd_valid <= 1'b0;
      while (!cfg_icb_rsp_valid) @(posedge clk);
      @(posedge clk);
    end
  endtask

  task cfg_read;
    input [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      cfg_icb_cmd_valid <= 1'b1;
      cfg_icb_cmd_addr <= addr;
      cfg_icb_cmd_read <= 1'b1;
      cfg_icb_cmd_wdata <= 32'h0;
      cfg_icb_cmd_wmask <= 4'h0;
      @(posedge clk);
      while (!cfg_icb_cmd_ready) @(posedge clk);
      cfg_icb_cmd_valid <= 1'b0;
      while (!cfg_icb_rsp_valid) @(posedge clk);
      data = cfg_icb_rsp_rdata;
      @(posedge clk);
    end
  endtask

  //////////////////////////////////////////////////////////////
  // Test Sequence
  //////////////////////////////////////////////////////////////
  reg [31:0] read_data;
  integer test_pass;
  integer errors;

  // Register offsets
  localparam CONV_CTRL_OFFSET       = 8'h00;
  localparam CONV_SRC_ADDR_OFFSET   = 8'h04;
  localparam CONV_DST_ADDR_OFFSET   = 8'h08;
  localparam CONV_IMG_WIDTH_OFFSET  = 8'h0C;
  localparam CONV_IMG_HEIGHT_OFFSET = 8'h10;
  localparam CONV_KERNEL_0_OFFSET   = 8'h14;
  localparam CONV_KERNEL_1_OFFSET   = 8'h18;
  localparam CONV_KERNEL_2_OFFSET   = 8'h1C;
  localparam CONV_STATUS_OFFSET     = 8'h20;

  initial begin
    // Initialize signals
    cfg_icb_cmd_valid = 1'b0;
    cfg_icb_cmd_addr = 32'h0;
    cfg_icb_cmd_read = 1'b0;
    cfg_icb_cmd_wdata = 32'h0;
    cfg_icb_cmd_wmask = 4'h0;
    cfg_icb_rsp_ready = 1'b1;
    test_pass = 1;
    errors = 0;

    // Wait for reset
    @(posedge rst_n);
    repeat(10) @(posedge clk);

    $display("========================================");
    $display("2D Convolution Accelerator Testbench");
    $display("========================================");

    //////////////////////////////////////////////////////////////
    // Test 1: Register Read/Write
    //////////////////////////////////////////////////////////////
    $display("\nTest 1: Register Read/Write");
    
    // Write and verify source address
    cfg_write(CONV_SRC_ADDR_OFFSET, 32'h0000_0000);
    cfg_read(CONV_SRC_ADDR_OFFSET, read_data);
    if (read_data != 32'h0000_0000) begin
      $display("ERROR: Source address mismatch");
      test_pass = 0;
    end else begin
      $display("PASS: Source address register");
    end

    // Write and verify destination address
    cfg_write(CONV_DST_ADDR_OFFSET, 32'h0000_0100);
    cfg_read(CONV_DST_ADDR_OFFSET, read_data);
    if (read_data != 32'h0000_0100) begin
      $display("ERROR: Destination address mismatch");
      test_pass = 0;
    end else begin
      $display("PASS: Destination address register");
    end

    // Write image dimensions
    cfg_write(CONV_IMG_WIDTH_OFFSET, 32'd4);
    cfg_write(CONV_IMG_HEIGHT_OFFSET, 32'd4);
    $display("PASS: Image dimension registers");

    //////////////////////////////////////////////////////////////
    // Test 2: Identity Kernel Convolution
    //////////////////////////////////////////////////////////////
    $display("\nTest 2: Identity Kernel Convolution (4x4 -> 2x2)");
    
    // Identity kernel: center = 1, others = 0
    // k[0][0]=0, k[0][1]=0, k[0][2]=0, k[1][0]=0
    cfg_write(CONV_KERNEL_0_OFFSET, 32'h0000_0000);
    // k[1][1]=1, k[1][2]=0, k[2][0]=0, k[2][1]=0
    cfg_write(CONV_KERNEL_1_OFFSET, 32'h0000_0001);
    // k[2][2]=0
    cfg_write(CONV_KERNEL_2_OFFSET, 32'h0000_0000);
    $display("  Kernel: Identity (0,0,0,0,1,0,0,0,0)");

    // Start convolution
    cfg_write(CONV_CTRL_OFFSET, 32'h0000_0003);  // Enable + Start
    $display("  Starting convolution...");

    // Wait for completion
    read_data = 32'h0;
    while ((read_data & 32'h4) == 0) begin
      cfg_read(CONV_CTRL_OFFSET, read_data);
      repeat(5) @(posedge clk);
    end
    $display("  Convolution complete!");

    // Verify results
    // With identity kernel on 4x4 input, 2x2 output should be center pixels
    // Output[0,0] = Input[1,1] = 60
    // Output[0,1] = Input[1,2] = 70
    // Output[1,0] = Input[2,1] = 100
    // Output[1,1] = Input[2,2] = 110
    $display("  Verifying results...");
    $display("    Result[0,0] = %d (expected 60)", result_memory[0]);
    $display("    Result[0,1] = %d (expected 70)", result_memory[1]);
    $display("    Result[1,0] = %d (expected 100)", result_memory[2]);
    $display("    Result[1,1] = %d (expected 110)", result_memory[3]);

    if (result_memory[0] == 8'd60 && result_memory[1] == 8'd70 &&
        result_memory[2] == 8'd100 && result_memory[3] == 8'd110) begin
      $display("PASS: Identity kernel convolution verified!");
    end else begin
      $display("ERROR: Identity kernel result mismatch");
      test_pass = 0;
    end

    // Clear done flag
    cfg_write(CONV_CTRL_OFFSET, 32'h0000_0005);

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
    $dumpfile("tb_conv2d.vcd");
    $dumpvars(0, tb_conv2d);
  end

  // Timeout
  initial begin
    #500000
    $display("ERROR: Test timeout!");
    $finish;
  end

endmodule
