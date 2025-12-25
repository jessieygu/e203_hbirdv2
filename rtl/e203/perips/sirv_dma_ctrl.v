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
// Designer   : DMA Module Extension
//
// Description:
//  Simple DMA Controller Module for E203 SoC
//  
//  This DMA controller supports:
//  - Memory-to-memory transfer
//  - Single channel DMA
//  - ICB master interface for memory access
//  - ICB slave interface for CPU configuration
//
//  Register Map (base + offset):
//  0x00: DMA_CTRL      - Control register (bit0: enable, bit1: start, bit2: done, bit3: busy)
//  0x04: DMA_SRC_ADDR  - Source address
//  0x08: DMA_DST_ADDR  - Destination address  
//  0x0C: DMA_XFER_LEN  - Transfer length (in bytes, must be 4-byte aligned)
//  0x10: DMA_STATUS    - Status register (read-only)
//
// ====================================================================

`include "e203_defines.v"

module sirv_dma_ctrl(
  // Clock and reset
  input  clk,
  input  rst_n,

  // DMA interrupt output
  output dma_irq,

  //////////////////////////////////////////////////////////////
  // ICB Slave interface for CPU configuration
  //////////////////////////////////////////////////////////////
  //    * Bus cmd channel
  input                          cfg_icb_cmd_valid,
  output                         cfg_icb_cmd_ready,
  input  [`E203_ADDR_SIZE-1:0]   cfg_icb_cmd_addr,
  input                          cfg_icb_cmd_read,
  input  [`E203_XLEN-1:0]        cfg_icb_cmd_wdata,
  input  [`E203_XLEN/8-1:0]      cfg_icb_cmd_wmask,
  
  //    * Bus RSP channel
  output                         cfg_icb_rsp_valid,
  input                          cfg_icb_rsp_ready,
  output                         cfg_icb_rsp_err,
  output [`E203_XLEN-1:0]        cfg_icb_rsp_rdata,

  //////////////////////////////////////////////////////////////
  // ICB Master interface for memory access
  //////////////////////////////////////////////////////////////
  //    * Bus cmd channel  
  output                         mst_icb_cmd_valid,
  input                          mst_icb_cmd_ready,
  output [`E203_ADDR_SIZE-1:0]   mst_icb_cmd_addr,
  output                         mst_icb_cmd_read,
  output [`E203_XLEN-1:0]        mst_icb_cmd_wdata,
  output [`E203_XLEN/8-1:0]      mst_icb_cmd_wmask,

  //    * Bus RSP channel
  input                          mst_icb_rsp_valid,
  output                         mst_icb_rsp_ready,
  input                          mst_icb_rsp_err,
  input  [`E203_XLEN-1:0]        mst_icb_rsp_rdata
);

  //////////////////////////////////////////////////////////////
  // Register definitions
  //////////////////////////////////////////////////////////////
  // DMA Control Register bits
  localparam DMA_CTRL_EN_BIT    = 0;  // DMA Enable
  localparam DMA_CTRL_START_BIT = 1;  // DMA Start (write 1 to start)
  localparam DMA_CTRL_DONE_BIT  = 2;  // DMA Done (read-only, write 1 to clear)
  localparam DMA_CTRL_BUSY_BIT  = 3;  // DMA Busy (read-only)
  localparam DMA_CTRL_IE_BIT    = 4;  // Interrupt Enable

  // Register addresses (offset from base)
  localparam DMA_CTRL_OFFSET     = 8'h00;
  localparam DMA_SRC_ADDR_OFFSET = 8'h04;
  localparam DMA_DST_ADDR_OFFSET = 8'h08;
  localparam DMA_XFER_LEN_OFFSET = 8'h0C;
  localparam DMA_STATUS_OFFSET   = 8'h10;

  // DMA state machine states
  localparam DMA_IDLE       = 3'd0;
  localparam DMA_READ_REQ   = 3'd1;
  localparam DMA_READ_RSP   = 3'd2;
  localparam DMA_WRITE_REQ  = 3'd3;
  localparam DMA_WRITE_RSP  = 3'd4;
  localparam DMA_DONE       = 3'd5;

  //////////////////////////////////////////////////////////////
  // Internal registers
  //////////////////////////////////////////////////////////////
  reg [31:0] dma_ctrl_r;
  reg [31:0] dma_src_addr_r;
  reg [31:0] dma_dst_addr_r;
  reg [31:0] dma_xfer_len_r;
  
  // DMA state machine
  reg [2:0]  dma_state;
  reg [31:0] bytes_transferred;
  reg [31:0] read_data_r;
  reg [31:0] current_src_addr;
  reg [31:0] current_dst_addr;
  
  // Derived signals
  wire dma_enabled = dma_ctrl_r[DMA_CTRL_EN_BIT];
  wire dma_start   = dma_ctrl_r[DMA_CTRL_START_BIT];
  wire dma_done    = dma_ctrl_r[DMA_CTRL_DONE_BIT];
  wire dma_busy    = (dma_state != DMA_IDLE);
  wire dma_ie      = dma_ctrl_r[DMA_CTRL_IE_BIT];

  //////////////////////////////////////////////////////////////
  // ICB Slave interface handling (CPU configuration)
  //////////////////////////////////////////////////////////////
  wire cfg_icb_cmd_hsked = cfg_icb_cmd_valid & cfg_icb_cmd_ready;
  wire [7:0] cfg_reg_offset = cfg_icb_cmd_addr[7:0];

  // Ready signal - always ready when not in reset
  assign cfg_icb_cmd_ready = 1'b1;
  
  // Response valid follows request with 1 cycle delay
  reg cfg_rsp_valid_r;
  reg [31:0] cfg_rsp_rdata_r;
  
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_rsp_valid_r <= 1'b0;
    end else begin
      cfg_rsp_valid_r <= cfg_icb_cmd_hsked;
    end
  end

  // Read data mux
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_rsp_rdata_r <= 32'b0;
    end else if (cfg_icb_cmd_hsked && cfg_icb_cmd_read) begin
      case (cfg_reg_offset)
        DMA_CTRL_OFFSET:     cfg_rsp_rdata_r <= {27'b0, dma_ie, dma_busy, dma_done, dma_start, dma_enabled};
        DMA_SRC_ADDR_OFFSET: cfg_rsp_rdata_r <= dma_src_addr_r;
        DMA_DST_ADDR_OFFSET: cfg_rsp_rdata_r <= dma_dst_addr_r;
        DMA_XFER_LEN_OFFSET: cfg_rsp_rdata_r <= dma_xfer_len_r;
        DMA_STATUS_OFFSET:   cfg_rsp_rdata_r <= bytes_transferred;
        default:             cfg_rsp_rdata_r <= 32'hDEAD_BEEF;
      endcase
    end
  end

  assign cfg_icb_rsp_valid = cfg_rsp_valid_r;
  assign cfg_icb_rsp_rdata = cfg_rsp_rdata_r;
  assign cfg_icb_rsp_err   = 1'b0;  // No errors

  //////////////////////////////////////////////////////////////
  // Register write handling
  //////////////////////////////////////////////////////////////
  wire cfg_wr_en = cfg_icb_cmd_hsked && !cfg_icb_cmd_read;
  
  // DMA Control register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_ctrl_r <= 32'b0;
    end else begin
      // Clear start bit automatically after starting
      if (dma_state == DMA_READ_REQ && dma_ctrl_r[DMA_CTRL_START_BIT]) begin
        dma_ctrl_r[DMA_CTRL_START_BIT] <= 1'b0;
      end
      // Set done bit when transfer completes
      if (dma_state == DMA_DONE) begin
        dma_ctrl_r[DMA_CTRL_DONE_BIT] <= 1'b1;
      end
      // Handle writes
      if (cfg_wr_en && cfg_reg_offset == DMA_CTRL_OFFSET) begin
        // Write 1 to clear done bit
        if (cfg_icb_cmd_wdata[DMA_CTRL_DONE_BIT] && cfg_icb_cmd_wmask[0]) begin
          dma_ctrl_r[DMA_CTRL_DONE_BIT] <= 1'b0;
        end
        // Other bits are writable
        if (cfg_icb_cmd_wmask[0]) begin
          dma_ctrl_r[DMA_CTRL_EN_BIT]    <= cfg_icb_cmd_wdata[DMA_CTRL_EN_BIT];
          dma_ctrl_r[DMA_CTRL_START_BIT] <= cfg_icb_cmd_wdata[DMA_CTRL_START_BIT];
          dma_ctrl_r[DMA_CTRL_IE_BIT]    <= cfg_icb_cmd_wdata[DMA_CTRL_IE_BIT];
        end
      end
    end
  end

  // Source address register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_src_addr_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == DMA_SRC_ADDR_OFFSET) begin
      dma_src_addr_r <= cfg_icb_cmd_wdata;
    end
  end

  // Destination address register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_dst_addr_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == DMA_DST_ADDR_OFFSET) begin
      dma_dst_addr_r <= cfg_icb_cmd_wdata;
    end
  end

  // Transfer length register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_xfer_len_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == DMA_XFER_LEN_OFFSET) begin
      dma_xfer_len_r <= cfg_icb_cmd_wdata;
    end
  end

  //////////////////////////////////////////////////////////////
  // DMA State Machine
  //////////////////////////////////////////////////////////////
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_state <= DMA_IDLE;
      bytes_transferred <= 32'b0;
      read_data_r <= 32'b0;
      current_src_addr <= 32'b0;
      current_dst_addr <= 32'b0;
    end else begin
      case (dma_state)
        DMA_IDLE: begin
          if (dma_enabled && dma_start && !dma_busy) begin
            // Start DMA transfer
            dma_state <= DMA_READ_REQ;
            bytes_transferred <= 32'b0;
            current_src_addr <= dma_src_addr_r;
            current_dst_addr <= dma_dst_addr_r;
          end
        end
        
        DMA_READ_REQ: begin
          // Issue read request
          if (mst_icb_cmd_ready) begin
            dma_state <= DMA_READ_RSP;
          end
        end
        
        DMA_READ_RSP: begin
          // Wait for read response
          if (mst_icb_rsp_valid) begin
            read_data_r <= mst_icb_rsp_rdata;
            dma_state <= DMA_WRITE_REQ;
          end
        end
        
        DMA_WRITE_REQ: begin
          // Issue write request
          if (mst_icb_cmd_ready) begin
            dma_state <= DMA_WRITE_RSP;
          end
        end
        
        DMA_WRITE_RSP: begin
          // Wait for write response
          if (mst_icb_rsp_valid) begin
            bytes_transferred <= bytes_transferred + 4;
            current_src_addr <= current_src_addr + 4;
            current_dst_addr <= current_dst_addr + 4;
            
            if ((bytes_transferred + 4) >= dma_xfer_len_r) begin
              // Transfer complete
              dma_state <= DMA_DONE;
            end else begin
              // Continue with next word
              dma_state <= DMA_READ_REQ;
            end
          end
        end
        
        DMA_DONE: begin
          // Transfer complete, go back to idle
          dma_state <= DMA_IDLE;
        end
        
        default: begin
          dma_state <= DMA_IDLE;
        end
      endcase
    end
  end

  //////////////////////////////////////////////////////////////
  // ICB Master interface signals
  //////////////////////////////////////////////////////////////
  // Command valid in read or write request states
  assign mst_icb_cmd_valid = (dma_state == DMA_READ_REQ) || (dma_state == DMA_WRITE_REQ);
  
  // Address is source for read, destination for write
  assign mst_icb_cmd_addr = (dma_state == DMA_READ_REQ) ? current_src_addr : current_dst_addr;
  
  // Read in READ_REQ state, write in WRITE_REQ state
  assign mst_icb_cmd_read = (dma_state == DMA_READ_REQ);
  
  // Write data from read buffer
  assign mst_icb_cmd_wdata = read_data_r;
  
  // Full word write mask
  assign mst_icb_cmd_wmask = 4'b1111;
  
  // Ready to accept response in response states
  assign mst_icb_rsp_ready = (dma_state == DMA_READ_RSP) || (dma_state == DMA_WRITE_RSP);

  //////////////////////////////////////////////////////////////
  // Interrupt generation
  //////////////////////////////////////////////////////////////
  assign dma_irq = dma_ie & dma_done;

endmodule
