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
// Designer   : 2D Convolution Accelerator
//
// Description:
//  Simple 3x3 2D Convolution Accelerator for E203 SoC
//  
//  This accelerator performs 3x3 convolution on input data and uses
//  DMA interface to store results back to memory.
//
//  Features:
//  - 3x3 fixed kernel convolution
//  - 8-bit input/output data
//  - Configurable kernel coefficients
//  - ICB slave interface for CPU configuration
//  - ICB master interface for memory access (via DMA)
//
//  Register Map (base + offset):
//  0x00: CONV_CTRL      - Control register (bit0: enable, bit1: start, bit2: done, bit3: busy)
//  0x04: CONV_SRC_ADDR  - Source image base address
//  0x08: CONV_DST_ADDR  - Destination result address
//  0x0C: CONV_IMG_WIDTH - Image width
//  0x10: CONV_IMG_HEIGHT- Image height
//  0x14: CONV_KERNEL_0  - Kernel coefficients [0][0], [0][1], [0][2], [1][0] (8-bit each)
//  0x18: CONV_KERNEL_1  - Kernel coefficients [1][1], [1][2], [2][0], [2][1] (8-bit each)
//  0x1C: CONV_KERNEL_2  - Kernel coefficient [2][2] and reserved
//  0x20: CONV_STATUS    - Status register (current position)
//
// ====================================================================

`include "e203_defines.v"

module sirv_conv2d_accel(
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
  // ICB Master interface for memory access
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
  localparam CONV_KERNEL_0_OFFSET   = 8'h14;
  localparam CONV_KERNEL_1_OFFSET   = 8'h18;
  localparam CONV_KERNEL_2_OFFSET   = 8'h1C;
  localparam CONV_STATUS_OFFSET     = 8'h20;

  // State machine states
  localparam CONV_IDLE        = 4'd0;
  localparam CONV_LOAD_ROW0   = 4'd1;
  localparam CONV_WAIT_ROW0   = 4'd2;
  localparam CONV_LOAD_ROW1   = 4'd3;
  localparam CONV_WAIT_ROW1   = 4'd4;
  localparam CONV_LOAD_ROW2   = 4'd5;
  localparam CONV_WAIT_ROW2   = 4'd6;
  localparam CONV_COMPUTE     = 4'd7;
  localparam CONV_CLAMP       = 4'd8;
  localparam CONV_WRITE_REQ   = 4'd9;
  localparam CONV_WRITE_RSP   = 4'd10;
  localparam CONV_NEXT_PIXEL  = 4'd11;
  localparam CONV_DONE        = 4'd12;

  //////////////////////////////////////////////////////////////
  // Internal registers
  //////////////////////////////////////////////////////////////
  reg [31:0] conv_ctrl_r;
  reg [31:0] conv_src_addr_r;
  reg [31:0] conv_dst_addr_r;
  reg [31:0] conv_img_width_r;
  reg [31:0] conv_img_height_r;
  reg [31:0] conv_kernel_0_r;  // k[0][0], k[0][1], k[0][2], k[1][0]
  reg [31:0] conv_kernel_1_r;  // k[1][1], k[1][2], k[2][0], k[2][1]
  reg [31:0] conv_kernel_2_r;  // k[2][2], reserved
  
  // State machine
  reg [3:0]  conv_state;
  reg [15:0] current_x;  // Current output pixel x position
  reg [15:0] current_y;  // Current output pixel y position
  
  // Pixel buffers for 3x3 window
  reg [7:0] pixel_00, pixel_01, pixel_02;
  reg [7:0] pixel_10, pixel_11, pixel_12;
  reg [7:0] pixel_20, pixel_21, pixel_22;
  
  // Computation result
  reg signed [31:0] conv_result;
  reg [7:0] output_pixel;
  
  // Derived signals
  wire conv_enabled = conv_ctrl_r[CONV_CTRL_EN_BIT];
  wire conv_start   = conv_ctrl_r[CONV_CTRL_START_BIT];
  wire conv_done    = conv_ctrl_r[CONV_CTRL_DONE_BIT];
  wire conv_busy    = (conv_state != CONV_IDLE);
  wire conv_ie      = conv_ctrl_r[CONV_CTRL_IE_BIT];

  // Kernel coefficients (signed 8-bit)
  wire signed [7:0] k00 = conv_kernel_0_r[7:0];
  wire signed [7:0] k01 = conv_kernel_0_r[15:8];
  wire signed [7:0] k02 = conv_kernel_0_r[23:16];
  wire signed [7:0] k10 = conv_kernel_0_r[31:24];
  wire signed [7:0] k11 = conv_kernel_1_r[7:0];
  wire signed [7:0] k12 = conv_kernel_1_r[15:8];
  wire signed [7:0] k20 = conv_kernel_1_r[23:16];
  wire signed [7:0] k21 = conv_kernel_1_r[31:24];
  wire signed [7:0] k22 = conv_kernel_2_r[7:0];

  // Output image dimensions (input - 2 for valid convolution)
  wire [15:0] output_width  = conv_img_width_r[15:0] - 16'd2;
  wire [15:0] output_height = conv_img_height_r[15:0] - 16'd2;

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
        CONV_KERNEL_0_OFFSET:   cfg_rsp_rdata_r <= conv_kernel_0_r;
        CONV_KERNEL_1_OFFSET:   cfg_rsp_rdata_r <= conv_kernel_1_r;
        CONV_KERNEL_2_OFFSET:   cfg_rsp_rdata_r <= conv_kernel_2_r;
        CONV_STATUS_OFFSET:     cfg_rsp_rdata_r <= {current_y, current_x};
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
      if (conv_state == CONV_LOAD_ROW0 && conv_ctrl_r[CONV_CTRL_START_BIT]) begin
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

  // Source address register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_src_addr_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == CONV_SRC_ADDR_OFFSET) begin
      conv_src_addr_r <= cfg_icb_cmd_wdata;
    end
  end

  // Destination address register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_dst_addr_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == CONV_DST_ADDR_OFFSET) begin
      conv_dst_addr_r <= cfg_icb_cmd_wdata;
    end
  end

  // Image width register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_img_width_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == CONV_IMG_WIDTH_OFFSET) begin
      conv_img_width_r <= cfg_icb_cmd_wdata;
    end
  end

  // Image height register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_img_height_r <= 32'b0;
    end else if (cfg_wr_en && cfg_reg_offset == CONV_IMG_HEIGHT_OFFSET) begin
      conv_img_height_r <= cfg_icb_cmd_wdata;
    end
  end

  // Kernel registers
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_kernel_0_r <= 32'b0;
      conv_kernel_1_r <= 32'b0;
      conv_kernel_2_r <= 32'b0;
    end else begin
      if (cfg_wr_en && cfg_reg_offset == CONV_KERNEL_0_OFFSET)
        conv_kernel_0_r <= cfg_icb_cmd_wdata;
      if (cfg_wr_en && cfg_reg_offset == CONV_KERNEL_1_OFFSET)
        conv_kernel_1_r <= cfg_icb_cmd_wdata;
      if (cfg_wr_en && cfg_reg_offset == CONV_KERNEL_2_OFFSET)
        conv_kernel_2_r <= cfg_icb_cmd_wdata;
    end
  end

  //////////////////////////////////////////////////////////////
  // Address calculation for pixel access
  //////////////////////////////////////////////////////////////
  // For row i, col j: address = src_addr + (current_y + i) * width + (current_x + j)
  wire [31:0] row0_addr = conv_src_addr_r + (current_y) * conv_img_width_r + current_x;
  wire [31:0] row1_addr = conv_src_addr_r + (current_y + 1) * conv_img_width_r + current_x;
  wire [31:0] row2_addr = conv_src_addr_r + (current_y + 2) * conv_img_width_r + current_x;
  wire [31:0] output_addr = conv_dst_addr_r + current_y * output_width + current_x;

  //////////////////////////////////////////////////////////////
  // Convolution State Machine
  //////////////////////////////////////////////////////////////
  reg [1:0] load_col;  // Track which column we're loading (0, 1, 2)
  reg [31:0] current_load_addr;
  reg load_pending;  // Track if we're waiting for memory response

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      conv_state <= CONV_IDLE;
      current_x <= 16'b0;
      current_y <= 16'b0;
      pixel_00 <= 8'b0; pixel_01 <= 8'b0; pixel_02 <= 8'b0;
      pixel_10 <= 8'b0; pixel_11 <= 8'b0; pixel_12 <= 8'b0;
      pixel_20 <= 8'b0; pixel_21 <= 8'b0; pixel_22 <= 8'b0;
      conv_result <= 32'b0;
      output_pixel <= 8'b0;
      load_col <= 2'b0;
      current_load_addr <= 32'b0;
      load_pending <= 1'b0;
    end else begin
      case (conv_state)
        CONV_IDLE: begin
          if (conv_enabled && conv_start && !conv_busy) begin
            conv_state <= CONV_LOAD_ROW0;
            current_x <= 16'b0;
            current_y <= 16'b0;
            load_col <= 2'b0;
            load_pending <= 1'b0;
          end
        end
        
        // Load 3 pixels from row 0
        CONV_LOAD_ROW0: begin
          if (!load_pending) begin
            current_load_addr <= row0_addr + {30'b0, load_col};
            load_pending <= 1'b1;
          end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
            case (load_col)
              2'd0: pixel_00 <= mst_icb_rsp_rdata[7:0];
              2'd1: pixel_01 <= mst_icb_rsp_rdata[7:0];
              2'd2: pixel_02 <= mst_icb_rsp_rdata[7:0];
            endcase
            load_pending <= 1'b0;
            if (load_col == 2'd2) begin
              load_col <= 2'b0;
              conv_state <= CONV_LOAD_ROW1;
            end else begin
              load_col <= load_col + 1;
            end
          end
        end
        
        // Load 3 pixels from row 1
        CONV_LOAD_ROW1: begin
          if (!load_pending) begin
            current_load_addr <= row1_addr + {30'b0, load_col};
            load_pending <= 1'b1;
          end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
            case (load_col)
              2'd0: pixel_10 <= mst_icb_rsp_rdata[7:0];
              2'd1: pixel_11 <= mst_icb_rsp_rdata[7:0];
              2'd2: pixel_12 <= mst_icb_rsp_rdata[7:0];
            endcase
            load_pending <= 1'b0;
            if (load_col == 2'd2) begin
              load_col <= 2'b0;
              conv_state <= CONV_LOAD_ROW2;
            end else begin
              load_col <= load_col + 1;
            end
          end
        end
        
        // Load 3 pixels from row 2
        CONV_LOAD_ROW2: begin
          if (!load_pending) begin
            current_load_addr <= row2_addr + {30'b0, load_col};
            load_pending <= 1'b1;
          end else if (mst_icb_rsp_valid && mst_icb_rsp_ready) begin
            case (load_col)
              2'd0: pixel_20 <= mst_icb_rsp_rdata[7:0];
              2'd1: pixel_21 <= mst_icb_rsp_rdata[7:0];
              2'd2: pixel_22 <= mst_icb_rsp_rdata[7:0];
            endcase
            load_pending <= 1'b0;
            if (load_col == 2'd2) begin
              load_col <= 2'b0;
              conv_state <= CONV_COMPUTE;
            end else begin
              load_col <= load_col + 1;
            end
          end
        end
        
        // Compute convolution
        CONV_COMPUTE: begin
          // Multiply-accumulate
          conv_result <= $signed({1'b0, pixel_00}) * k00 +
                         $signed({1'b0, pixel_01}) * k01 +
                         $signed({1'b0, pixel_02}) * k02 +
                         $signed({1'b0, pixel_10}) * k10 +
                         $signed({1'b0, pixel_11}) * k11 +
                         $signed({1'b0, pixel_12}) * k12 +
                         $signed({1'b0, pixel_20}) * k20 +
                         $signed({1'b0, pixel_21}) * k21 +
                         $signed({1'b0, pixel_22}) * k22;
          conv_state <= CONV_CLAMP;
        end
        
        // Clamp and prepare output
        CONV_CLAMP: begin
          // Clamp result to 0-255
          if (conv_result < 0)
            output_pixel <= 8'd0;
          else if (conv_result > 255)
            output_pixel <= 8'd255;
          else
            output_pixel <= conv_result[7:0];
          conv_state <= CONV_WRITE_REQ;
        end
        
        // Write result using DMA
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
        
        // Move to next pixel
        CONV_NEXT_PIXEL: begin
          if (current_x + 1 >= output_width) begin
            current_x <= 16'b0;
            if (current_y + 1 >= output_height) begin
              conv_state <= CONV_DONE;
            end else begin
              current_y <= current_y + 1;
              conv_state <= CONV_LOAD_ROW0;
            end
          end else begin
            current_x <= current_x + 1;
            conv_state <= CONV_LOAD_ROW0;
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
  // Read commands during load states when pending, write during write state
  wire is_loading = ((conv_state == CONV_LOAD_ROW0) || 
                     (conv_state == CONV_LOAD_ROW1) || 
                     (conv_state == CONV_LOAD_ROW2)) && load_pending;
  wire is_writing = (conv_state == CONV_WRITE_REQ);

  assign mst_icb_cmd_valid = is_loading || is_writing;
  assign mst_icb_cmd_addr = is_writing ? output_addr : current_load_addr;
  assign mst_icb_cmd_read = is_loading;
  assign mst_icb_cmd_wdata = {24'b0, output_pixel};
  assign mst_icb_cmd_wmask = 4'b0001;  // Only write lowest byte
  
  assign mst_icb_rsp_ready = is_loading || (conv_state == CONV_WRITE_RSP);

  //////////////////////////////////////////////////////////////
  // Interrupt generation
  //////////////////////////////////////////////////////////////
  assign conv_irq = conv_ie & conv_done;

endmodule
