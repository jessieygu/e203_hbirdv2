/*
 * Simple 2D Convolution Algorithm in C
 * 
 * This program demonstrates a simple 3x3 2D convolution operation
 * that can be used with the E203 DMA controller and convolution accelerator.
 * 
 * Usage:
 *   1. Configure the convolution accelerator registers
 *   2. Start the convolution operation
 *   3. Results are stored via DMA to destination address
 * 
 * Register Map:
 *   CONV_BASE + 0x00: Control (enable, start, done, busy, irq_en)
 *   CONV_BASE + 0x04: Source address
 *   CONV_BASE + 0x08: Destination address  
 *   CONV_BASE + 0x0C: Image width
 *   CONV_BASE + 0x10: Image height
 *   CONV_BASE + 0x14: Kernel coefficients [0][0], [0][1], [0][2], [1][0]
 *   CONV_BASE + 0x18: Kernel coefficients [1][1], [1][2], [2][0], [2][1]
 *   CONV_BASE + 0x1C: Kernel coefficient [2][2]
 *   CONV_BASE + 0x20: Status (current x, y position)
 */

#include <stdint.h>

// Base addresses (example, adjust for your memory map)
#define CONV_BASE       0x10043000
#define DMA_BASE        0x10042000
#define IMAGE_SRC_ADDR  0x90000000  // DTCM
#define IMAGE_DST_ADDR  0x90001000  // DTCM

// Convolution registers
#define CONV_CTRL       (*(volatile uint32_t*)(CONV_BASE + 0x00))
#define CONV_SRC_ADDR   (*(volatile uint32_t*)(CONV_BASE + 0x04))
#define CONV_DST_ADDR   (*(volatile uint32_t*)(CONV_BASE + 0x08))
#define CONV_IMG_WIDTH  (*(volatile uint32_t*)(CONV_BASE + 0x0C))
#define CONV_IMG_HEIGHT (*(volatile uint32_t*)(CONV_BASE + 0x10))
#define CONV_KERNEL_0   (*(volatile uint32_t*)(CONV_BASE + 0x14))
#define CONV_KERNEL_1   (*(volatile uint32_t*)(CONV_BASE + 0x18))
#define CONV_KERNEL_2   (*(volatile uint32_t*)(CONV_BASE + 0x1C))
#define CONV_STATUS     (*(volatile uint32_t*)(CONV_BASE + 0x20))

// DMA registers
#define DMA_CTRL        (*(volatile uint32_t*)(DMA_BASE + 0x00))
#define DMA_SRC_ADDR    (*(volatile uint32_t*)(DMA_BASE + 0x04))
#define DMA_DST_ADDR    (*(volatile uint32_t*)(DMA_BASE + 0x08))
#define DMA_XFER_LEN    (*(volatile uint32_t*)(DMA_BASE + 0x0C))
#define DMA_STATUS      (*(volatile uint32_t*)(DMA_BASE + 0x10))

// Control register bits
#define CTRL_ENABLE     (1 << 0)
#define CTRL_START      (1 << 1)
#define CTRL_DONE       (1 << 2)
#define CTRL_BUSY       (1 << 3)
#define CTRL_IRQ_EN     (1 << 4)

// Image dimensions for test
#define IMG_WIDTH   8
#define IMG_HEIGHT  8
#define OUT_WIDTH   (IMG_WIDTH - 2)
#define OUT_HEIGHT  (IMG_HEIGHT - 2)

// Test image data (8x8 grayscale)
static const uint8_t test_image[IMG_HEIGHT][IMG_WIDTH] = {
    {  0,  10,  20,  30,  40,  50,  60,  70},
    { 10,  20,  30,  40,  50,  60,  70,  80},
    { 20,  30,  40,  50,  60,  70,  80,  90},
    { 30,  40,  50,  60,  70,  80,  90, 100},
    { 40,  50,  60,  70,  80,  90, 100, 110},
    { 50,  60,  70,  80,  90, 100, 110, 120},
    { 60,  70,  80,  90, 100, 110, 120, 130},
    { 70,  80,  90, 100, 110, 120, 130, 140}
};

// 3x3 Edge detection kernel (Sobel-like horizontal)
static const int8_t kernel[3][3] = {
    {-1,  0,  1},
    {-2,  0,  2},
    {-1,  0,  1}
};

// Software reference convolution
void conv2d_sw(const uint8_t* src, uint8_t* dst, 
               int img_width, int img_height,
               const int8_t kernel[3][3]) {
    int out_width = img_width - 2;
    int out_height = img_height - 2;
    
    for (int y = 0; y < out_height; y++) {
        for (int x = 0; x < out_width; x++) {
            int32_t sum = 0;
            
            // 3x3 convolution
            for (int ky = 0; ky < 3; ky++) {
                for (int kx = 0; kx < 3; kx++) {
                    int src_idx = (y + ky) * img_width + (x + kx);
                    sum += (int32_t)src[src_idx] * kernel[ky][kx];
                }
            }
            
            // Clamp result to 0-255
            if (sum < 0) sum = 0;
            if (sum > 255) sum = 255;
            
            dst[y * out_width + x] = (uint8_t)sum;
        }
    }
}

// Pack kernel coefficients into register format
uint32_t pack_kernel_0(const int8_t k[3][3]) {
    return ((uint32_t)(uint8_t)k[0][0]) |
           ((uint32_t)(uint8_t)k[0][1] << 8) |
           ((uint32_t)(uint8_t)k[0][2] << 16) |
           ((uint32_t)(uint8_t)k[1][0] << 24);
}

uint32_t pack_kernel_1(const int8_t k[3][3]) {
    return ((uint32_t)(uint8_t)k[1][1]) |
           ((uint32_t)(uint8_t)k[1][2] << 8) |
           ((uint32_t)(uint8_t)k[2][0] << 16) |
           ((uint32_t)(uint8_t)k[2][1] << 24);
}

uint32_t pack_kernel_2(const int8_t k[3][3]) {
    return (uint32_t)(uint8_t)k[2][2];
}

// Initialize convolution accelerator
void conv2d_hw_init(uint32_t src_addr, uint32_t dst_addr,
                    int img_width, int img_height,
                    const int8_t kernel[3][3]) {
    // Set source and destination addresses
    CONV_SRC_ADDR = src_addr;
    CONV_DST_ADDR = dst_addr;
    
    // Set image dimensions
    CONV_IMG_WIDTH = img_width;
    CONV_IMG_HEIGHT = img_height;
    
    // Set kernel coefficients
    CONV_KERNEL_0 = pack_kernel_0(kernel);
    CONV_KERNEL_1 = pack_kernel_1(kernel);
    CONV_KERNEL_2 = pack_kernel_2(kernel);
}

// Start convolution hardware
void conv2d_hw_start(void) {
    // Enable and start
    CONV_CTRL = CTRL_ENABLE | CTRL_START;
}

// Wait for convolution to complete
void conv2d_hw_wait(void) {
    while (!(CONV_CTRL & CTRL_DONE)) {
        // Wait
    }
    // Clear done flag
    CONV_CTRL = CTRL_DONE | CTRL_ENABLE;
}

// Use DMA to copy data
void dma_copy(uint32_t src, uint32_t dst, uint32_t len) {
    DMA_SRC_ADDR = src;
    DMA_DST_ADDR = dst;
    DMA_XFER_LEN = len;
    DMA_CTRL = CTRL_ENABLE | CTRL_START;
    
    // Wait for DMA completion
    while (!(DMA_CTRL & CTRL_DONE)) {
        // Wait
    }
    // Clear done flag
    DMA_CTRL = CTRL_DONE;
}

// Main function demonstrating usage
int main(void) {
    uint8_t output_sw[OUT_HEIGHT * OUT_WIDTH];
    uint8_t* src_mem = (uint8_t*)IMAGE_SRC_ADDR;
    uint8_t* dst_mem = (uint8_t*)IMAGE_DST_ADDR;
    
    // Copy test image to source memory using DMA
    // (In real hardware, you would use DMA to copy from external memory)
    for (int i = 0; i < IMG_HEIGHT * IMG_WIDTH; i++) {
        src_mem[i] = ((uint8_t*)test_image)[i];
    }
    
    // Method 1: Software convolution (reference)
    conv2d_sw((uint8_t*)test_image, output_sw, IMG_WIDTH, IMG_HEIGHT, kernel);
    
    // Method 2: Hardware convolution with DMA output
    conv2d_hw_init(IMAGE_SRC_ADDR, IMAGE_DST_ADDR, IMG_WIDTH, IMG_HEIGHT, kernel);
    conv2d_hw_start();
    conv2d_hw_wait();
    
    // Optionally use DMA to copy results to another location
    // dma_copy(IMAGE_DST_ADDR, RESULT_ADDR, OUT_WIDTH * OUT_HEIGHT);
    
    // Verify results
    int errors = 0;
    for (int i = 0; i < OUT_WIDTH * OUT_HEIGHT; i++) {
        if (dst_mem[i] != output_sw[i]) {
            errors++;
        }
    }
    
    return errors;
}

/*
 * Example kernel configurations:
 * 
 * 1. Identity kernel (no change):
 *    { 0, 0, 0 }
 *    { 0, 1, 0 }
 *    { 0, 0, 0 }
 * 
 * 2. Edge detection (horizontal):
 *    { -1,  0,  1 }
 *    { -2,  0,  2 }
 *    { -1,  0,  1 }
 * 
 * 3. Edge detection (vertical):
 *    { -1, -2, -1 }
 *    {  0,  0,  0 }
 *    {  1,  2,  1 }
 * 
 * 4. Sharpen:
 *    {  0, -1,  0 }
 *    { -1,  5, -1 }
 *    {  0, -1,  0 }
 * 
 * 5. Box blur (average):
 *    { 1, 1, 1 }
 *    { 1, 1, 1 }   (divide result by 9)
 *    { 1, 1, 1 }
 */
