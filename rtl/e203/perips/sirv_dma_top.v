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
//  DMA Top Module that wraps the DMA controller
//  and provides interfaces to both ITCM and DTCM
//
//  The DMA can access both ITCM and DTCM based on address decoding:
//  - ITCM: 0x8000_0000 - 0x8FFF_FFFF
//  - DTCM: 0x9000_0000 - 0x9FFF_FFFF
//
// ====================================================================

`include "e203_defines.v"

module sirv_dma_top(
  // Clock and reset
  input  clk,
  input  rst_n,

  // DMA interrupt output
  output dma_irq,

  //////////////////////////////////////////////////////////////
  // ICB Slave interface for CPU configuration
  //////////////////////////////////////////////////////////////
  input                          dma_icb_cmd_valid,
  output                         dma_icb_cmd_ready,
  input  [`E203_ADDR_SIZE-1:0]   dma_icb_cmd_addr,
  input                          dma_icb_cmd_read,
  input  [`E203_XLEN-1:0]        dma_icb_cmd_wdata,
  input  [`E203_XLEN/8-1:0]      dma_icb_cmd_wmask,
  
  output                         dma_icb_rsp_valid,
  input                          dma_icb_rsp_ready,
  output                         dma_icb_rsp_err,
  output [`E203_XLEN-1:0]        dma_icb_rsp_rdata,

  `ifdef E203_HAS_ITCM_EXTITF //{
  //////////////////////////////////////////////////////////////
  // ICB Master interface to ITCM
  //////////////////////////////////////////////////////////////
  output                         dma2itcm_icb_cmd_valid,
  input                          dma2itcm_icb_cmd_ready,
  output [`E203_ITCM_ADDR_WIDTH-1:0] dma2itcm_icb_cmd_addr,
  output                         dma2itcm_icb_cmd_read,
  output [`E203_XLEN-1:0]        dma2itcm_icb_cmd_wdata,
  output [`E203_XLEN/8-1:0]      dma2itcm_icb_cmd_wmask,

  input                          dma2itcm_icb_rsp_valid,
  output                         dma2itcm_icb_rsp_ready,
  input                          dma2itcm_icb_rsp_err,
  input  [`E203_XLEN-1:0]        dma2itcm_icb_rsp_rdata,
  `endif//}

  `ifdef E203_HAS_DTCM_EXTITF //{
  //////////////////////////////////////////////////////////////
  // ICB Master interface to DTCM
  //////////////////////////////////////////////////////////////
  output                         dma2dtcm_icb_cmd_valid,
  input                          dma2dtcm_icb_cmd_ready,
  output [`E203_DTCM_ADDR_WIDTH-1:0] dma2dtcm_icb_cmd_addr,
  output                         dma2dtcm_icb_cmd_read,
  output [`E203_XLEN-1:0]        dma2dtcm_icb_cmd_wdata,
  output [`E203_XLEN/8-1:0]      dma2dtcm_icb_cmd_wmask,

  input                          dma2dtcm_icb_rsp_valid,
  output                         dma2dtcm_icb_rsp_ready,
  input                          dma2dtcm_icb_rsp_err,
  input  [`E203_XLEN-1:0]        dma2dtcm_icb_rsp_rdata
  `endif//}
);

  // Internal signals from DMA controller
  wire                         mst_icb_cmd_valid;
  wire                         mst_icb_cmd_ready;
  wire [`E203_ADDR_SIZE-1:0]   mst_icb_cmd_addr;
  wire                         mst_icb_cmd_read;
  wire [`E203_XLEN-1:0]        mst_icb_cmd_wdata;
  wire [`E203_XLEN/8-1:0]      mst_icb_cmd_wmask;

  wire                         mst_icb_rsp_valid;
  wire                         mst_icb_rsp_ready;
  wire                         mst_icb_rsp_err;
  wire [`E203_XLEN-1:0]        mst_icb_rsp_rdata;

  //////////////////////////////////////////////////////////////
  // Instantiate DMA Controller
  //////////////////////////////////////////////////////////////
  sirv_dma_ctrl u_sirv_dma_ctrl(
    .clk                (clk),
    .rst_n              (rst_n),
    
    .dma_irq            (dma_irq),
    
    // Configuration interface
    .cfg_icb_cmd_valid  (dma_icb_cmd_valid),
    .cfg_icb_cmd_ready  (dma_icb_cmd_ready),
    .cfg_icb_cmd_addr   (dma_icb_cmd_addr),
    .cfg_icb_cmd_read   (dma_icb_cmd_read),
    .cfg_icb_cmd_wdata  (dma_icb_cmd_wdata),
    .cfg_icb_cmd_wmask  (dma_icb_cmd_wmask),
    
    .cfg_icb_rsp_valid  (dma_icb_rsp_valid),
    .cfg_icb_rsp_ready  (dma_icb_rsp_ready),
    .cfg_icb_rsp_err    (dma_icb_rsp_err),
    .cfg_icb_rsp_rdata  (dma_icb_rsp_rdata),
    
    // Master interface (to memory)
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
  // Address decode for ITCM and DTCM routing
  // ITCM: 0x8000_0000 - 0x8FFF_FFFF (bit 31:28 = 0x8)
  // DTCM: 0x9000_0000 - 0x9FFF_FFFF (bit 31:28 = 0x9)
  //////////////////////////////////////////////////////////////
  wire sel_itcm = (mst_icb_cmd_addr[31:28] == 4'h8);
  wire sel_dtcm = (mst_icb_cmd_addr[31:28] == 4'h9);
  
  // Track which target was selected for response routing
  reg sel_itcm_r;
  reg sel_dtcm_r;
  
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_itcm_r <= 1'b0;
      sel_dtcm_r <= 1'b0;
    end else if (mst_icb_cmd_valid && mst_icb_cmd_ready) begin
      sel_itcm_r <= sel_itcm;
      sel_dtcm_r <= sel_dtcm;
    end
  end

  `ifdef E203_HAS_ITCM_EXTITF //{
  //////////////////////////////////////////////////////////////
  // ITCM Interface
  //////////////////////////////////////////////////////////////
  assign dma2itcm_icb_cmd_valid = mst_icb_cmd_valid & sel_itcm;
  assign dma2itcm_icb_cmd_addr  = mst_icb_cmd_addr[`E203_ITCM_ADDR_WIDTH-1:0];
  assign dma2itcm_icb_cmd_read  = mst_icb_cmd_read;
  assign dma2itcm_icb_cmd_wdata = mst_icb_cmd_wdata;
  assign dma2itcm_icb_cmd_wmask = mst_icb_cmd_wmask;
  assign dma2itcm_icb_rsp_ready = mst_icb_rsp_ready & sel_itcm_r;
  `endif//}

  `ifdef E203_HAS_DTCM_EXTITF //{
  //////////////////////////////////////////////////////////////
  // DTCM Interface
  //////////////////////////////////////////////////////////////
  assign dma2dtcm_icb_cmd_valid = mst_icb_cmd_valid & sel_dtcm;
  assign dma2dtcm_icb_cmd_addr  = mst_icb_cmd_addr[`E203_DTCM_ADDR_WIDTH-1:0];
  assign dma2dtcm_icb_cmd_read  = mst_icb_cmd_read;
  assign dma2dtcm_icb_cmd_wdata = mst_icb_cmd_wdata;
  assign dma2dtcm_icb_cmd_wmask = mst_icb_cmd_wmask;
  assign dma2dtcm_icb_rsp_ready = mst_icb_rsp_ready & sel_dtcm_r;
  `endif//}

  //////////////////////////////////////////////////////////////
  // Ready and Response muxing
  //////////////////////////////////////////////////////////////
  
  // Detect invalid address access (neither ITCM nor DTCM)
  wire sel_invalid = ~sel_itcm & ~sel_dtcm;
  reg sel_invalid_r;
  
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_invalid_r <= 1'b0;
    end else if (mst_icb_cmd_valid && mst_icb_cmd_ready) begin
      sel_invalid_r <= sel_invalid;
    end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
      sel_invalid_r <= 1'b0;  // Clear after response completes
    end
  end
  
  `ifdef E203_HAS_ITCM_EXTITF //{
    `ifdef E203_HAS_DTCM_EXTITF //{
      // Both ITCM and DTCM interfaces available
      // For invalid addresses, return ready immediately and provide error response
      assign mst_icb_cmd_ready = sel_itcm ? dma2itcm_icb_cmd_ready :
                                 sel_dtcm ? dma2dtcm_icb_cmd_ready : 1'b1;
      assign mst_icb_rsp_valid = sel_itcm_r ? dma2itcm_icb_rsp_valid :
                                 sel_dtcm_r ? dma2dtcm_icb_rsp_valid : sel_invalid_r;
      assign mst_icb_rsp_err   = sel_itcm_r ? dma2itcm_icb_rsp_err :
                                 sel_dtcm_r ? dma2dtcm_icb_rsp_err : 1'b1;
      assign mst_icb_rsp_rdata = sel_itcm_r ? dma2itcm_icb_rsp_rdata :
                                 sel_dtcm_r ? dma2dtcm_icb_rsp_rdata : 32'h0;
    `else//}{
      // Only ITCM interface available
      assign mst_icb_cmd_ready = sel_itcm ? dma2itcm_icb_cmd_ready : 1'b1;
      assign mst_icb_rsp_valid = sel_itcm_r ? dma2itcm_icb_rsp_valid : sel_invalid_r;
      assign mst_icb_rsp_err   = sel_itcm_r ? dma2itcm_icb_rsp_err : 1'b1;
      assign mst_icb_rsp_rdata = sel_itcm_r ? dma2itcm_icb_rsp_rdata : 32'h0;
    `endif//}
  `else//}{
    `ifdef E203_HAS_DTCM_EXTITF //{
      // Only DTCM interface available
      assign mst_icb_cmd_ready = sel_dtcm ? dma2dtcm_icb_cmd_ready : 1'b1;
      assign mst_icb_rsp_valid = sel_dtcm_r ? dma2dtcm_icb_rsp_valid : sel_invalid_r;
      assign mst_icb_rsp_err   = sel_dtcm_r ? dma2dtcm_icb_rsp_err : 1'b1;
      assign mst_icb_rsp_rdata = sel_dtcm_r ? dma2dtcm_icb_rsp_rdata : 32'h0;
    `else//}{
      // No external TCM interfaces - always return error response
      assign mst_icb_cmd_ready = 1'b1;
      assign mst_icb_rsp_valid = sel_invalid_r;
      assign mst_icb_rsp_err   = 1'b1;
      assign mst_icb_rsp_rdata = 32'h0;
    `endif//}
  `endif//}

endmodule
