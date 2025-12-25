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
// Designer   : DMA Module Testbench
//
// Description:
//  Standalone testbench for DMA controller module
//  Tests basic read/write operations and DMA transfers
//
// ====================================================================

`timescale 1ns/1ps

module tb_dma();

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
  // DUT Signals
  //////////////////////////////////////////////////////////////
  // Configuration interface
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

  // Master interface (to memory)
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

  wire                 dma_irq;

  //////////////////////////////////////////////////////////////
  // DUT Instance
  //////////////////////////////////////////////////////////////
  sirv_dma_ctrl u_dut (
    .clk                (clk),
    .rst_n              (rst_n),
    
    .dma_irq            (dma_irq),
    
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
  // Simple Memory Model
  //////////////////////////////////////////////////////////////
  reg [31:0] memory [0:255];  // 1KB memory
  integer i;

  initial begin
    // Initialize memory with test pattern
    for (i = 0; i < 256; i = i + 1) begin
      memory[i] = 32'hDEAD_0000 + i;
    end
  end

  // Memory response state machine
  reg [2:0] mem_state;
  reg [7:0] mem_addr_latch;

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
      mem_addr_latch <= 8'h0;
    end else begin
      case (mem_state)
        MEM_IDLE: begin
          if (mst_icb_cmd_valid && mst_icb_cmd_ready) begin
            mem_addr_latch <= mst_icb_cmd_addr[9:2];  // Word address
            if (mst_icb_cmd_read) begin
              mem_state <= MEM_READ_RSP;
              mst_icb_rsp_rdata <= memory[mst_icb_cmd_addr[9:2]];
              mst_icb_rsp_valid <= 1'b1;
            end else begin
              // Write operation
              memory[mst_icb_cmd_addr[9:2]] <= mst_icb_cmd_wdata;
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
      // Wait for response
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
      // Wait for response
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

  initial begin
    // Initialize signals
    cfg_icb_cmd_valid = 1'b0;
    cfg_icb_cmd_addr = 32'h0;
    cfg_icb_cmd_read = 1'b0;
    cfg_icb_cmd_wdata = 32'h0;
    cfg_icb_cmd_wmask = 4'h0;
    cfg_icb_rsp_ready = 1'b1;
    test_pass = 1;

    // Wait for reset
    @(posedge rst_n);
    repeat(10) @(posedge clk);

    $display("========================================");
    $display("DMA Controller Testbench");
    $display("========================================");

    //////////////////////////////////////////////////////////////
    // Test 1: Register Read/Write
    //////////////////////////////////////////////////////////////
    $display("\nTest 1: Register Read/Write");
    
    // Write source address
    cfg_write(32'h04, 32'h0000_0000);  // Source: memory[0]
    cfg_read(32'h04, read_data);
    if (read_data != 32'h0000_0000) begin
      $display("ERROR: Source address mismatch. Expected 0x00000000, Got 0x%08h", read_data);
      test_pass = 0;
    end else begin
      $display("PASS: Source address register");
    end

    // Write destination address
    cfg_write(32'h08, 32'h0000_0080);  // Destination: memory[32]
    cfg_read(32'h08, read_data);
    if (read_data != 32'h0000_0080) begin
      $display("ERROR: Destination address mismatch. Expected 0x00000080, Got 0x%08h", read_data);
      test_pass = 0;
    end else begin
      $display("PASS: Destination address register");
    end

    // Write transfer length (16 bytes = 4 words)
    cfg_write(32'h0C, 32'h0000_0010);
    cfg_read(32'h0C, read_data);
    if (read_data != 32'h0000_0010) begin
      $display("ERROR: Transfer length mismatch. Expected 0x00000010, Got 0x%08h", read_data);
      test_pass = 0;
    end else begin
      $display("PASS: Transfer length register");
    end

    //////////////////////////////////////////////////////////////
    // Test 2: DMA Transfer
    //////////////////////////////////////////////////////////////
    $display("\nTest 2: DMA Transfer (4 words from addr 0 to addr 128)");
    
    // Enable DMA and start transfer (bit 0 = enable, bit 1 = start)
    cfg_write(32'h00, 32'h0000_0003);

    // Wait for DMA to complete
    read_data = 32'h0;
    while ((read_data & 32'h4) == 0) begin  // Wait for done bit
      cfg_read(32'h00, read_data);
      repeat(5) @(posedge clk);
    end
    $display("DMA transfer complete. Control register: 0x%08h", read_data);

    // Verify the transfer
    $display("Verifying transfer...");
    if (memory[32] == memory[0] && memory[33] == memory[1] && 
        memory[34] == memory[2] && memory[35] == memory[3]) begin
      $display("PASS: DMA transfer verified");
      $display("  memory[32] = 0x%08h (expected 0x%08h)", memory[32], 32'hDEAD_0000);
      $display("  memory[33] = 0x%08h (expected 0x%08h)", memory[33], 32'hDEAD_0001);
      $display("  memory[34] = 0x%08h (expected 0x%08h)", memory[34], 32'hDEAD_0002);
      $display("  memory[35] = 0x%08h (expected 0x%08h)", memory[35], 32'hDEAD_0003);
    end else begin
      $display("ERROR: DMA transfer verification failed");
      $display("  memory[32] = 0x%08h (expected 0x%08h)", memory[32], 32'hDEAD_0000);
      $display("  memory[33] = 0x%08h (expected 0x%08h)", memory[33], 32'hDEAD_0001);
      $display("  memory[34] = 0x%08h (expected 0x%08h)", memory[34], 32'hDEAD_0002);
      $display("  memory[35] = 0x%08h (expected 0x%08h)", memory[35], 32'hDEAD_0003);
      test_pass = 0;
    end

    // Clear done bit
    cfg_write(32'h00, 32'h0000_0005);  // Write 1 to done bit to clear

    //////////////////////////////////////////////////////////////
    // Test 3: Check bytes transferred
    //////////////////////////////////////////////////////////////
    $display("\nTest 3: Check bytes transferred");
    cfg_read(32'h10, read_data);
    if (read_data == 32'h10) begin
      $display("PASS: Bytes transferred = %d", read_data);
    end else begin
      $display("ERROR: Bytes transferred mismatch. Expected 16, Got %d", read_data);
      test_pass = 0;
    end

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
    $dumpfile("tb_dma.vcd");
    $dumpvars(0, tb_dma);
  end

  // Timeout
  initial begin
    #100000
    $display("ERROR: Test timeout!");
    $finish;
  end

endmodule
