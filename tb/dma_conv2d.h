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

/**
 * @file dma_conv2d.h
 * @brief DMA Controller and 2D Convolution Driver Header
 * 
 * This header provides register definitions and driver functions for
 * the DMA controller used with 2D convolution operations on the
 * Hummingbirdv2 E203 SoC.
 */

#ifndef __DMA_CONV2D_H__
#define __DMA_CONV2D_H__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*============================================================================
 * DMA Controller Register Definitions
 *============================================================================*/

/**
 * @brief DMA Base Address (adjust based on actual memory map)
 */
#ifndef DMA_BASE_ADDR
#define DMA_BASE_ADDR           0x10040000UL
#endif

/**
 * @brief DMA Register Offsets
 */
#define DMA_REG_CTRL            0x00    /**< Control register */
#define DMA_REG_SRC_ADDR        0x04    /**< Source address register */
#define DMA_REG_DST_ADDR        0x08    /**< Destination address register */
#define DMA_REG_LENGTH          0x0C    /**< Transfer length register */
#define DMA_REG_STATUS          0x10    /**< Status register */

/**
 * @brief DMA Register Access Macros
 */
#define DMA_REG(offset)         (*(volatile uint32_t*)(DMA_BASE_ADDR + (offset)))
#define DMA_CTRL                DMA_REG(DMA_REG_CTRL)
#define DMA_SRC_ADDR            DMA_REG(DMA_REG_SRC_ADDR)
#define DMA_DST_ADDR            DMA_REG(DMA_REG_DST_ADDR)
#define DMA_LENGTH              DMA_REG(DMA_REG_LENGTH)
#define DMA_STATUS              DMA_REG(DMA_REG_STATUS)

/**
 * @brief DMA Control Register Bits
 */
#define DMA_CTRL_START          (1U << 0)   /**< Start transfer */
#define DMA_CTRL_DONE           (1U << 1)   /**< Transfer done (read-only) */
#define DMA_CTRL_IRQ_EN         (1U << 2)   /**< Enable interrupt */

/**
 * @brief DMA Status Register Bits
 */
#define DMA_STATUS_BUSY         (1U << 0)   /**< DMA is busy */
#define DMA_STATUS_DONE         (1U << 1)   /**< Transfer complete */
#define DMA_STATUS_ERROR        (1U << 2)   /**< Transfer error */

/*============================================================================
 * DMA Driver Functions
 *============================================================================*/

/**
 * @brief Initialize DMA controller
 */
static inline void dma_init(void) {
    /* Clear any pending status */
    (void)DMA_STATUS;
}

/**
 * @brief Check if DMA is busy
 * @return 1 if busy, 0 if idle
 */
static inline int dma_is_busy(void) {
    return (DMA_STATUS & DMA_STATUS_BUSY) ? 1 : 0;
}

/**
 * @brief Check if DMA transfer is done
 * @return 1 if done, 0 otherwise
 */
static inline int dma_is_done(void) {
    return (DMA_STATUS & DMA_STATUS_DONE) ? 1 : 0;
}

/**
 * @brief Check if DMA transfer had error
 * @return 1 if error, 0 otherwise
 */
static inline int dma_has_error(void) {
    return (DMA_STATUS & DMA_STATUS_ERROR) ? 1 : 0;
}

/**
 * @brief Wait for DMA to become idle
 */
static inline void dma_wait_idle(void) {
    while (dma_is_busy()) {
        /* Busy wait */
    }
}

/**
 * @brief Wait for DMA transfer to complete
 */
static inline void dma_wait_done(void) {
    while (!dma_is_done()) {
        /* Busy wait */
    }
}

/**
 * @brief Start a DMA transfer
 * @param src Source address (must be 4-byte aligned)
 * @param dst Destination address (must be 4-byte aligned)
 * @param len Transfer length in 32-bit words
 * @return 0 on success, -1 if DMA is busy
 */
static inline int dma_transfer(uint32_t src, uint32_t dst, uint32_t len) {
    /* Wait for DMA to be idle */
    if (dma_is_busy()) {
        return -1;
    }
    
    /* Configure transfer */
    DMA_SRC_ADDR = src;
    DMA_DST_ADDR = dst;
    DMA_LENGTH = len;
    
    /* Start transfer */
    DMA_CTRL = DMA_CTRL_START;
    
    return 0;
}

/**
 * @brief Perform blocking DMA transfer
 * @param src Source address (must be 4-byte aligned)
 * @param dst Destination address (must be 4-byte aligned)
 * @param len Transfer length in 32-bit words
 * @return 0 on success, -1 on error
 */
static inline int dma_transfer_blocking(uint32_t src, uint32_t dst, uint32_t len) {
    /* Wait for DMA to be idle */
    dma_wait_idle();
    
    /* Configure and start transfer */
    DMA_SRC_ADDR = src;
    DMA_DST_ADDR = dst;
    DMA_LENGTH = len;
    DMA_CTRL = DMA_CTRL_START;
    
    /* Wait for completion */
    dma_wait_done();
    
    /* Check for errors */
    if (dma_has_error()) {
        return -1;
    }
    
    return 0;
}

/*============================================================================
 * 2D Convolution Functions
 *============================================================================*/

/**
 * @brief Perform 3x3 2D convolution
 * @param input Pointer to input image data (int8_t)
 * @param output Pointer to output buffer (int8_t)
 * @param kernel 3x3 convolution kernel (int8_t[3][3])
 * @param img_width Input image width
 * @param img_height Input image height
 * 
 * Output dimensions will be (img_width-2) x (img_height-2)
 */
static inline void conv2d_3x3(const int8_t* input, int8_t* output,
                               const int8_t kernel[3][3],
                               int img_width, int img_height) {
    int out_width = img_width - 2;
    int out_height = img_height - 2;
    int x, y, kx, ky;
    
    for (y = 0; y < out_height; y++) {
        for (x = 0; x < out_width; x++) {
            int32_t sum = 0;
            for (ky = 0; ky < 3; ky++) {
                for (kx = 0; kx < 3; kx++) {
                    int idx = (y + ky) * img_width + (x + kx);
                    sum += (int32_t)input[idx] * (int32_t)kernel[ky][kx];
                }
            }
            /* Saturate to int8 range */
            if (sum > 127) sum = 127;
            if (sum < -128) sum = -128;
            output[y * out_width + x] = (int8_t)sum;
        }
    }
}

/**
 * @brief Sobel X edge detection kernel
 */
static const int8_t SOBEL_X_KERNEL[3][3] = {
    {-1, 0, 1},
    {-2, 0, 2},
    {-1, 0, 1}
};

/**
 * @brief Sobel Y edge detection kernel
 */
static const int8_t SOBEL_Y_KERNEL[3][3] = {
    {-1, -2, -1},
    { 0,  0,  0},
    { 1,  2,  1}
};

/**
 * @brief Laplacian edge detection kernel
 */
static const int8_t LAPLACIAN_KERNEL[3][3] = {
    { 0, -1,  0},
    {-1,  4, -1},
    { 0, -1,  0}
};

/**
 * @brief Box blur (average) kernel (multiply result by 1/9)
 * Note: This uses integer kernel, divide result by 9 for proper blur
 */
static const int8_t BOX_BLUR_KERNEL[3][3] = {
    {1, 1, 1},
    {1, 1, 1},
    {1, 1, 1}
};

/**
 * @brief Perform convolution and transfer result using DMA
 * @param input Pointer to input image
 * @param conv_output Temporary buffer for convolution output
 * @param dma_dst DMA destination address
 * @param kernel Convolution kernel
 * @param img_width Input image width
 * @param img_height Input image height
 * @return 0 on success, -1 on error
 */
static inline int conv2d_with_dma(const int8_t* input, int8_t* conv_output,
                                   uint32_t dma_dst,
                                   const int8_t kernel[3][3],
                                   int img_width, int img_height) {
    int out_width = img_width - 2;
    int out_height = img_height - 2;
    uint32_t out_bytes = out_width * out_height;
    uint32_t out_words = (out_bytes + 3) / 4;  /* Round up to 32-bit words */
    
    /* Perform convolution */
    conv2d_3x3(input, conv_output, kernel, img_width, img_height);
    
    /* Transfer result using DMA */
    return dma_transfer_blocking((uint32_t)conv_output, dma_dst, out_words);
}

#ifdef __cplusplus
}
#endif

#endif /* __DMA_CONV2D_H__ */
