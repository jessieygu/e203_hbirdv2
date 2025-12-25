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
// Designer   : Multi-Channel 2D Convolution Accelerator
//
// Description:
//  Multi-channel 3x3 2D Convolution Accelerator for E203 SoC
//  
//  Parameters:
//  - Input feature map: 16×16×3 (width×height×channels)
//  - Kernel: 3×3×3 (width×height×channels)
//  - Padding: Invalid (no padding)
//  - Stride: 1
//  - Data width: 32-bit per element
//  - Output: 14×14×3 (width×height×channels)
//
//  Register Map (base + offset):
//  0x00: CONV_CTRL      - Control register (bit0: enable, bit1: start, bit2: done, bit3: busy)
//  0x04: CONV_SRC_ADDR  - Source feature map base address
//  0x08: CONV_DST_ADDR  - Destination result address
//  0x0C: CONV_IMG_WIDTH - Image width (default 16)
//  0x10: CONV_IMG_HEIGHT- Image height (default 16)
//  0x14: CONV_CHANNELS  - Number of channels (default 3)
//  0x18: CONV_KERNEL_BASE - Kernel coefficients base address
//  0x1C: CONV_STATUS    - Status register (current position)
//
// ====================================================================

`include "e203_defines.v"

module sirv_conv2d_multichan(
  // Clock and reset
  input  clk,
  input  rst_n,

  // Convolution done interrupt output
  output conv_irq,

  //////////////////////////////////////////////////////////////
  // ICB Slave interface for CPU configuration
  //////////////////////////////////////////////////////////////
  input                          cfg_icb_cmd_valid,
  output                         cfg_icb_cmd_ready,
  input  [`E203_ADDR_SIZE-1:0]   cfg_icb_cmd_addr,
  input                          cfg_icb_cmd_read,
  input  [`E203_XLEN-1:0]        cfg_icb_cmd_wdata,
  input  [`E203_XLEN/8-1:0]      cfg_icb_cmd_wmask,
  
  output                         cfg_icb_rsp_valid,
  input                          cfg_icb_rsp_ready,
  output                         cfg_icb_rsp_err,
  output [`E203_XLEN-1:0]        cfg_icb_rsp_rdata,

  //////////////////////////////////////////////////////////////
  // ICB Master interface for memory access (DMA-like)
  //////////////////////////////////////////////////////////////
  output                         mst_icb_cmd_valid,
  input                          mst_icb_cmd_ready,
  output [`E203_ADDR_SIZE-1:0]   mst_icb_cmd_addr,
  output                         mst_icb_cmd_read,
  output [`E203_XLEN-1:0]        mst_icb_cmd_wdata,
  output [`E203_XLEN/8-1:0]      mst_icb_cmd_wmask,

  input                          mst_icb_rsp_valid,
  output                         mst_icb_rsp_ready,
  input                          mst_icb_rsp_err,
  input  [`E203_XLEN-1:0]        mst_icb_rsp_rdata
);

  //////////////////////////////////////////////////////////////
  // Parameters
  //////////////////////////////////////////////////////////////
  localparam INPUT_WIDTH  = 16;
  localparam INPUT_HEIGHT = 16;
  localparam NUM_CHANNELS = 3;
  localparam KERNEL_SIZE  = 3;
  localparam OUTPUT_WIDTH  = INPUT_WIDTH - KERNEL_SIZE + 1;   // 14
  localparam OUTPUT_HEIGHT = INPUT_HEIGHT - KERNEL_SIZE + 1;  // 14
  
  //////////////////////////////////////////////////////////////
  // Register definitions
  //////////////////////////////////////////////////////////////
  localparam CONV_CTRL_EN_BIT    = 0;
  localparam CONV_CTRL_START_BIT = 1;
  localparam CONV_CTRL_DONE_BIT  = 2;
  localparam CONV_CTRL_BUSY_BIT  = 3;
  localparam CONV_CTRL_IE_BIT    = 4;

  // Register addresses (offset from base)
  localparam CONV_CTRL_OFFSET       = 8'h00;
  localparam CONV_SRC_ADDR_OFFSET   = 8'h04;
  localparam CONV_DST_ADDR_OFFSET   = 8'h08;
  localparam CONV_IMG_WIDTH_OFFSET  = 8'h0C;
  localparam CONV_IMG_HEIGHT_OFFSET = 8'h10;
  localparam CONV_CHANNELS_OFFSET   = 8'h14;
  localparam CONV_KERNEL_OFFSET     = 8'h18;
  localparam CONV_STATUS_OFFSET     = 8'h1C;

  // State machine states
  localparam CONV_IDLE        = 4'd0;
  localparam CONV_LOAD_KERNEL = 4'd1;
  localparam CONV_WAIT_KERNEL = 4'd2;
  localparam CONV_LOAD_DATA   = 4'd3;
  localparam CONV_WAIT_DATA   = 4'd4;
  localparam CONV_COMPUTE     = 4'd5;
  localparam CONV_CLAMP       = 4'd6;
  localparam CONV_WRITE_REQ   = 4'd7;
  localparam CONV_WRITE_RSP   = 4'd8;
  localparam CONV_NEXT_PIXEL  = 4'd9;
  localparam CONV_NEXT_CHAN   = 4'd10;
  localparam CONV_DONE        = 4'd11;

  //////////////////////////////////////////////////////////////
  // Internal registers
  //////////////////////////////////////////////////////////////
  reg [31:0] conv_ctrl_r;
  reg [31:0] conv_src_addr_r;
  reg [31:0] conv_dst_addr_r;
  reg [31:0] conv_img_width_r;
  reg [31:0] conv_img_height_r;
  reg [31:0] conv_channels_r;
  reg [31:0] conv_kernel_addr_r;
  
  // State machine
  reg [3:0]  conv_state;
  reg [7:0]  current_x;    // Current output pixel x position (0-13)
  reg [7:0]  current_y;    // Current output pixel y position (0-13)
  reg [1:0]  current_chan; // Current channel (0-2)
  
  // 3x3 kernel buffer for current channel (32-bit each)
  reg signed [31:0] kernel [0:8];
  
  // 3x3 data buffer for current window (32-bit each)
  reg signed [31:0] data_window [0:8];
  
  // Loading counters
  reg [3:0] load_idx;  // Index for loading (0-8 for 3x3)
  reg load_pending;
  reg [31:0] current_load_addr;
  
  // Computation result
  reg signed [63:0] conv_result;  // Wide to handle multiplication overflow
  reg [31:0] output_value;
  
  // Derived signals
  wire conv_enabled = conv_ctrl_r[CONV_CTRL_EN_BIT];
  wire conv_start   = conv_ctrl_r[CONV_CTRL_START_BIT];
  wire conv_done    = conv_ctrl_r[CONV_CTRL_DONE_BIT];
  wire conv_busy    = (conv_state != CONV_IDLE);
  wire conv_ie      = conv_ctrl_r[CONV_CTRL_IE_BIT];

  // Output dimensions
  wire [7:0] output_width  = conv_img_width_r[7:0] - 8'd2;   // 14 for 16 input
  wire [7:0] output_height = conv_img_height_r[7:0] - 8'd2;  // 14 for 16 input

  //////////////////////////////////////////////////////////////
  // ICB Slave interface handling (CPU configuration)
  //////////////////////////////////////////////////////////////
  wire cfg_icb_cmd_hsked = cfg_icb_cmd_valid & cfg_icb_cmd_ready;
  wire [7:0] cfg_reg_offset = cfg_icb_cmd_addr[7:0];

  assign cfg_icb_cmd_ready = 1'b1;
  
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
        CONV_CTRL_OFFSET:       cfg_rsp_rdata_r <= {27'b0, conv_ie, conv_busy, conv_done, conv_start, conv_enabled};
        CONV_SRC_ADDR_OFFSET:   cfg_rsp_rdata_r <= conv_src_addr_r;
        CONV_DST_ADDR_OFFSET:   cfg_rsp_rdata_r <= conv_dst_addr_r;
        CONV_IMG_WIDTH_OFFSET:  cfg_rsp_rdata_r <= conv_img_width_r;
        CONV_IMG_HEIGHT_OFFSET: cfg_rsp_rdata_r <= conv_img_height_r;
        CONV_CHANNELS_OFFSET:   cfg_rsp_rdata_r <= conv_channels_r;
        CONV_KERNEL_OFFSET:     cfg_rsp_rdata_r <= conv_kernel_addr_r;
        CONV_STATUS_OFFSET:     cfg_rsp_rdata_r <= {8'b0, current_chan, 6'b0, current_y, current_x};
        default:                cfg_rsp_rdata_r <= 32'hDEAD_BEEF;
      endcase
    end
  end

  assign cfg_icb_rsp_valid = cfg_rsp_valid_r;
  assign cfg_icb_rsp_rdata = cfg_rsp_rdata_r;
  assign cfg_icb_rsp_err   = 1'b0;

  //////////////////////////////////////////////////////////////
  // Register write handling
  //////////////////////////////////////////////////////////////
  wire cfg_wr_en = cfg_icb_cmd_hsked && !cfg_icb_cmd_read;
  
  // Control register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_ctrl_r <= 32'b0;
    end else begin
      // Clear start bit automatically
      if (conv_state == CONV_LOAD_KERNEL && conv_ctrl_r[CONV_CTRL_START_BIT]) begin
        conv_ctrl_r[CONV_CTRL_START_BIT] <= 1'b0;
      end
      // Set done bit when complete
      if (conv_state == CONV_DONE) begin
        conv_ctrl_r[CONV_CTRL_DONE_BIT] <= 1'b1;
      end
      // Handle writes
      if (cfg_wr_en && cfg_reg_offset == CONV_CTRL_OFFSET) begin
        if (cfg_icb_cmd_wdata[CONV_CTRL_DONE_BIT] && cfg_icb_cmd_wmask[0]) begin
          conv_ctrl_r[CONV_CTRL_DONE_BIT] <= 1'b0;  // Write 1 to clear
        end
        if (cfg_icb_cmd_wmask[0]) begin
          conv_ctrl_r[CONV_CTRL_EN_BIT]    <= cfg_icb_cmd_wdata[CONV_CTRL_EN_BIT];
          conv_ctrl_r[CONV_CTRL_START_BIT] <= cfg_icb_cmd_wdata[CONV_CTRL_START_BIT];
          conv_ctrl_r[CONV_CTRL_IE_BIT]    <= cfg_icb_cmd_wdata[CONV_CTRL_IE_BIT];
        end
      end
    end
  end

  // Configuration registers
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_src_addr_r <= 32'b0;
      conv_dst_addr_r <= 32'b0;
      conv_img_width_r <= 32'd16;   // Default 16
      conv_img_height_r <= 32'd16;  // Default 16
      conv_channels_r <= 32'd3;     // Default 3 channels
      conv_kernel_addr_r <= 32'b0;
    end else begin
      if (cfg_wr_en) begin
        case (cfg_reg_offset)
          CONV_SRC_ADDR_OFFSET:   conv_src_addr_r <= cfg_icb_cmd_wdata;
          CONV_DST_ADDR_OFFSET:   conv_dst_addr_r <= cfg_icb_cmd_wdata;
          CONV_IMG_WIDTH_OFFSET:  conv_img_width_r <= cfg_icb_cmd_wdata;
          CONV_IMG_HEIGHT_OFFSET: conv_img_height_r <= cfg_icb_cmd_wdata;
          CONV_CHANNELS_OFFSET:   conv_channels_r <= cfg_icb_cmd_wdata;
          CONV_KERNEL_OFFSET:     conv_kernel_addr_r <= cfg_icb_cmd_wdata;
        endcase
      end
    end
  end

  //////////////////////////////////////////////////////////////
  // Address calculation
  //////////////////////////////////////////////////////////////
  // Feature map layout: [channel][row][col] - 32-bit per element
  // Address = base + (channel * height * width + row * width + col) * 4
  
  // Kernel address for loading: kernel[channel][kernel_row][kernel_col]
  // kernel_addr = kernel_base + (channel * 9 + load_idx) * 4
  wire [31:0] kernel_load_addr = conv_kernel_addr_r + ({24'b0, current_chan} * 36) + ({28'b0, load_idx} << 2);
  
  // Data load address calculation using lookup for row/col offsets
  // load_idx: 0 1 2 3 4 5 6 7 8
  // row_off:  0 0 0 1 1 1 2 2 2
  // col_off:  0 1 2 0 1 2 0 1 2
  reg [1:0] row_offset;
  reg [1:0] col_offset;
  
  always @(*) begin
    case (load_idx)
      4'd0: begin row_offset = 2'd0; col_offset = 2'd0; end
      4'd1: begin row_offset = 2'd0; col_offset = 2'd1; end
      4'd2: begin row_offset = 2'd0; col_offset = 2'd2; end
      4'd3: begin row_offset = 2'd1; col_offset = 2'd0; end
      4'd4: begin row_offset = 2'd1; col_offset = 2'd1; end
      4'd5: begin row_offset = 2'd1; col_offset = 2'd2; end
      4'd6: begin row_offset = 2'd2; col_offset = 2'd0; end
      4'd7: begin row_offset = 2'd2; col_offset = 2'd1; end
      4'd8: begin row_offset = 2'd2; col_offset = 2'd2; end
      default: begin row_offset = 2'd0; col_offset = 2'd0; end
    endcase
  end
  
  wire [7:0] data_row = current_y + {6'b0, row_offset};
  wire [7:0] data_col = current_x + {6'b0, col_offset};
  
  // Calculate feature map element index: channel*H*W + row*W + col
  wire [31:0] feature_idx = ({24'b0, current_chan} * conv_img_height_r[7:0] * conv_img_width_r[7:0]) +
                            ({24'b0, data_row} * conv_img_width_r[7:0]) +
                            {24'b0, data_col};
  wire [31:0] data_load_addr = conv_src_addr_r + (feature_idx << 2);
  
  // Output address calculation
  wire [31:0] output_idx = ({24'b0, current_chan} * {24'b0, output_height} * {24'b0, output_width}) +
                           ({24'b0, current_y} * {24'b0, output_width}) +
                           {24'b0, current_x};
  wire [31:0] output_addr = conv_dst_addr_r + (output_idx << 2);

  //////////////////////////////////////////////////////////////
  // Convolution State Machine
  //////////////////////////////////////////////////////////////
  integer i;
  
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_state <= CONV_IDLE;
      current_x <= 8'b0;
      current_y <= 8'b0;
      current_chan <= 2'b0;
      load_idx <= 4'b0;
      load_pending <= 1'b0;
      current_load_addr <= 32'b0;
      conv_result <= 64'b0;
      output_value <= 32'b0;
      for (i = 0; i < 9; i = i + 1) begin
        kernel[i] <= 32'b0;
        data_window[i] <= 32'b0;
      end
    end else begin
      case (conv_state)
        CONV_IDLE: begin
          if (conv_enabled && conv_start && !conv_busy) begin
            conv_state <= CONV_LOAD_KERNEL;
            current_x <= 8'b0;
            current_y <= 8'b0;
            current_chan <= 2'b0;
            load_idx <= 4'b0;
            load_pending <= 1'b0;
          end
        end
        
        // Load 3x3 kernel for current channel
        CONV_LOAD_KERNEL: begin
          if (!load_pending) begin
            current_load_addr <= kernel_load_addr;
            load_pending <= 1'b1;
          end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
            kernel[load_idx] <= mst_icb_rsp_rdata;
            load_pending <= 1'b0;
            if (load_idx == 4'd8) begin
              load_idx <= 4'b0;
              conv_state <= CONV_LOAD_DATA;
            end else begin
              load_idx <= load_idx + 1;
            end
          end
        end
        
        // Load 3x3 data window
        CONV_LOAD_DATA: begin
          if (!load_pending) begin
            current_load_addr <= data_load_addr;
            load_pending <= 1'b1;
          end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
            data_window[load_idx] <= mst_icb_rsp_rdata;
            load_pending <= 1'b0;
            if (load_idx == 4'd8) begin
              load_idx <= 4'b0;
              conv_state <= CONV_COMPUTE;
            end else begin
              load_idx <= load_idx + 1;
            end
          end
        end
        
        // Compute convolution for current window
        CONV_COMPUTE: begin
          // 3x3 dot product
          conv_result <= data_window[0] * kernel[0] +
                         data_window[1] * kernel[1] +
                         data_window[2] * kernel[2] +
                         data_window[3] * kernel[3] +
                         data_window[4] * kernel[4] +
                         data_window[5] * kernel[5] +
                         data_window[6] * kernel[6] +
                         data_window[7] * kernel[7] +
                         data_window[8] * kernel[8];
          conv_state <= CONV_CLAMP;
        end
        
        // Clamp and prepare output value
        CONV_CLAMP: begin
          // Clamp/saturate result to 32-bit
          if (conv_result[63]) begin
            output_value <= 32'h0;  // Clamp negative to 0
          end else if (|conv_result[63:32]) begin
            output_value <= 32'hFFFFFFFF;  // Clamp overflow to max
          end else begin
            output_value <= conv_result[31:0];
          end
          conv_state <= CONV_WRITE_REQ;
        end
        
        // Write result via DMA
        CONV_WRITE_REQ: begin
          if (mst_icb_cmd_ready) begin
            conv_state <= CONV_WRITE_RSP;
          end
        end
        
        CONV_WRITE_RSP: begin
          if (mst_icb_rsp_valid) begin
            conv_state <= CONV_NEXT_PIXEL;
          end
        end
        
        // Move to next output pixel
        CONV_NEXT_PIXEL: begin
          if (current_x + 1 >= output_width) begin
            current_x <= 8'b0;
            if (current_y + 1 >= output_height) begin
              current_y <= 8'b0;
              conv_state <= CONV_NEXT_CHAN;
            end else begin
              current_y <= current_y + 1;
              conv_state <= CONV_LOAD_DATA;  // Same kernel, new position
            end
          end else begin
            current_x <= current_x + 1;
            conv_state <= CONV_LOAD_DATA;  // Same kernel, new position
          end
          load_pending <= 1'b0;
        end
        
        // Move to next channel
        CONV_NEXT_CHAN: begin
          if (current_chan + 1 >= conv_channels_r[1:0]) begin
            conv_state <= CONV_DONE;
          end else begin
            current_chan <= current_chan + 1;
            conv_state <= CONV_LOAD_KERNEL;  // Load new kernel
          end
          load_pending <= 1'b0;
        end
        
        CONV_DONE: begin
          conv_state <= CONV_IDLE;
        end
        
        default: begin
          conv_state <= CONV_IDLE;
        end
      endcase
    end
  end

  //////////////////////////////////////////////////////////////
  // ICB Master interface signals
  //////////////////////////////////////////////////////////////
  wire is_loading = ((conv_state == CONV_LOAD_KERNEL) || 
                     (conv_state == CONV_LOAD_DATA)) && load_pending;
  wire is_writing = (conv_state == CONV_WRITE_REQ);

  assign mst_icb_cmd_valid = is_loading || is_writing;
  assign mst_icb_cmd_addr = is_writing ? output_addr : current_load_addr;
  assign mst_icb_cmd_read = is_loading;
  assign mst_icb_cmd_wdata = output_value;
  assign mst_icb_cmd_wmask = 4'b1111;  // Full 32-bit write
  
  assign mst_icb_rsp_ready = is_loading || (conv_state == CONV_WRITE_RSP);

  //////////////////////////////////////////////////////////////
  // Interrupt generation
  //////////////////////////////////////////////////////////////
  assign conv_irq = conv_ie & conv_done;

endmodule
