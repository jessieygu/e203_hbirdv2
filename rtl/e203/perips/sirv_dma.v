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
// Designer   : DMA Controller
//
// Description:
//  Simple DMA controller for data transfer between memory regions
//  Supports burst transfers for convolution acceleration
//
// Register Map (APB interface, base offset 0x0):
//  0x00: CTRL     - Control register [0]=start, [1]=done(RO), [2]=irq_en
//  0x04: SRC_ADDR - Source address
//  0x08: DST_ADDR - Destination address  
//  0x0C: LENGTH   - Transfer length (in 32-bit words)
//  0x10: STATUS   - Status register [0]=busy, [1]=done, [2]=error
//
// ====================================================================

module sirv_dma (
    input  wire        clk,
    input  wire        rst_n,
    
    // APB Slave Interface for configuration
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    
    // Memory Interface for DMA transfers (Master)
    output reg         dma_cmd_valid,
    input  wire        dma_cmd_ready,
    output reg  [31:0] dma_cmd_addr,
    output reg         dma_cmd_read,
    output reg  [31:0] dma_cmd_wdata,
    output reg  [3:0]  dma_cmd_wmask,
    
    input  wire        dma_rsp_valid,
    output wire        dma_rsp_ready,
    input  wire        dma_rsp_err,
    input  wire [31:0] dma_rsp_rdata,
    
    // Interrupt output
    output wire        dma_irq
);

    // Register addresses
    localparam ADDR_CTRL     = 12'h000;
    localparam ADDR_SRC      = 12'h004;
    localparam ADDR_DST      = 12'h008;
    localparam ADDR_LENGTH   = 12'h00C;
    localparam ADDR_STATUS   = 12'h010;

    // Control register bits
    reg        ctrl_start;
    reg        ctrl_irq_en;
    
    // Configuration registers
    reg [31:0] src_addr;
    reg [31:0] dst_addr;
    reg [31:0] length;
    
    // Status bits
    reg        status_busy;
    reg        status_done;
    reg        status_error;
    
    // DMA state machine
    localparam IDLE       = 3'd0;
    localparam READ_REQ   = 3'd1;
    localparam READ_RSP   = 3'd2;
    localparam WRITE_REQ  = 3'd3;
    localparam WRITE_RSP  = 3'd4;
    localparam DONE       = 3'd5;
    
    reg [2:0]  state;
    reg [31:0] transfer_cnt;
    reg [31:0] read_data;
    reg [31:0] current_src;
    reg [31:0] current_dst;
    
    // APB interface
    assign pready  = 1'b1;
    assign pslverr = 1'b0;
    
    // DMA response ready
    assign dma_rsp_ready = (state == READ_RSP) || (state == WRITE_RSP);
    
    // Interrupt generation
    assign dma_irq = ctrl_irq_en & status_done;
    
    // APB Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_start  <= 1'b0;
            ctrl_irq_en <= 1'b0;
            src_addr    <= 32'h0;
            dst_addr    <= 32'h0;
            length      <= 32'h0;
        end else if (psel && penable && pwrite) begin
            case (paddr)
                ADDR_CTRL: begin
                    ctrl_start  <= pwdata[0];
                    ctrl_irq_en <= pwdata[2];
                end
                ADDR_SRC:    src_addr <= pwdata;
                ADDR_DST:    dst_addr <= pwdata;
                ADDR_LENGTH: length   <= pwdata;
                default: ;
            endcase
        end else begin
            // Auto-clear start bit
            if (state != IDLE) begin
                ctrl_start <= 1'b0;
            end
        end
    end
    
    // APB Read Logic
    always @(*) begin
        case (paddr)
            ADDR_CTRL:   prdata = {29'b0, ctrl_irq_en, status_done, ctrl_start};
            ADDR_SRC:    prdata = src_addr;
            ADDR_DST:    prdata = dst_addr;
            ADDR_LENGTH: prdata = length;
            ADDR_STATUS: prdata = {29'b0, status_error, status_done, status_busy};
            default:     prdata = 32'h0;
        endcase
    end
    
    // DMA State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            status_busy  <= 1'b0;
            status_done  <= 1'b0;
            status_error <= 1'b0;
            transfer_cnt <= 32'h0;
            read_data    <= 32'h0;
            current_src  <= 32'h0;
            current_dst  <= 32'h0;
            dma_cmd_valid <= 1'b0;
            dma_cmd_addr  <= 32'h0;
            dma_cmd_read  <= 1'b0;
            dma_cmd_wdata <= 32'h0;
            dma_cmd_wmask <= 4'h0;
        end else begin
            case (state)
                IDLE: begin
                    if (ctrl_start && (length > 0)) begin
                        state        <= READ_REQ;
                        status_busy  <= 1'b1;
                        status_done  <= 1'b0;
                        status_error <= 1'b0;
                        transfer_cnt <= 32'h0;
                        current_src  <= src_addr;
                        current_dst  <= dst_addr;
                    end
                end
                
                READ_REQ: begin
                    dma_cmd_valid <= 1'b1;
                    dma_cmd_addr  <= current_src;
                    dma_cmd_read  <= 1'b1;
                    dma_cmd_wmask <= 4'h0;
                    if (dma_cmd_ready) begin
                        dma_cmd_valid <= 1'b0;
                        state <= READ_RSP;
                    end
                end
                
                READ_RSP: begin
                    if (dma_rsp_valid) begin
                        if (dma_rsp_err) begin
                            status_error <= 1'b1;
                            state <= DONE;
                        end else begin
                            read_data <= dma_rsp_rdata;
                            state <= WRITE_REQ;
                        end
                    end
                end
                
                WRITE_REQ: begin
                    dma_cmd_valid <= 1'b1;
                    dma_cmd_addr  <= current_dst;
                    dma_cmd_read  <= 1'b0;
                    dma_cmd_wdata <= read_data;
                    dma_cmd_wmask <= 4'hF;
                    if (dma_cmd_ready) begin
                        dma_cmd_valid <= 1'b0;
                        state <= WRITE_RSP;
                    end
                end
                
                WRITE_RSP: begin
                    if (dma_rsp_valid) begin
                        if (dma_rsp_err) begin
                            status_error <= 1'b1;
                            state <= DONE;
                        end else begin
                            transfer_cnt <= transfer_cnt + 1'b1;
                            current_src  <= current_src + 4;
                            current_dst  <= current_dst + 4;
                            if (transfer_cnt + 1 >= length) begin
                                state <= DONE;
                            end else begin
                                state <= READ_REQ;
                            end
                        end
                    end
                end
                
                DONE: begin
                    status_busy <= 1'b0;
                    status_done <= 1'b1;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
