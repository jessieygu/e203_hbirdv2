/*
 * Multi-Channel 2D Convolution Algorithm in C
 * 
 * This program demonstrates multi-channel 3x3 2D convolution operation
 * for the E203 DMA controller and convolution accelerator.
 * 
 * Parameters:
 *   - Feature map: 16×16×3 (width×height×channels)
 *   - Kernel: 3×3×3 (width×height×channels)
 *   - Padding: Invalid (no padding)
 *   - Stride: 1
 *   - Data width: 32-bit per element
 *   - Output: 14×14×3 (width×height×channels)
 *
 * Register Map:
 *   CONV_BASE + 0x00: Control (enable, start, done, busy, irq_en)
 *   CONV_BASE + 0x04: Source feature map address
 *   CONV_BASE + 0x08: Destination result address  
 *   CONV_BASE + 0x0C: Image width (16)
 *   CONV_BASE + 0x10: Image height (16)
 *   CONV_BASE + 0x14: Number of channels (3)
 *   CONV_BASE + 0x18: Kernel base address
 *   CONV_BASE + 0x1C: Status (current position)
 */

#include <stdint.h>
#include <string.h>

// Base addresses (example, adjust for your memory map)
#define CONV_BASE       0x10043000
#define DMA_BASE        0x10042000
#define IMAGE_SRC_ADDR  0x90000000  // DTCM - Feature map
#define IMAGE_DST_ADDR  0x90002000  // DTCM - Output
#define KERNEL_ADDR     0x90001000  // DTCM - Kernel
#define DMA_DST_ADDR    0x90003000  // DTCM - DMA destination

// Multi-channel Convolution registers
#define CONV_CTRL       (*(volatile uint32_t*)(CONV_BASE + 0x00))
#define CONV_SRC_ADDR   (*(volatile uint32_t*)(CONV_BASE + 0x04))
#define CONV_DST_ADDR   (*(volatile uint32_t*)(CONV_BASE + 0x08))
#define CONV_IMG_WIDTH  (*(volatile uint32_t*)(CONV_BASE + 0x0C))
#define CONV_IMG_HEIGHT (*(volatile uint32_t*)(CONV_BASE + 0x10))
#define CONV_CHANNELS   (*(volatile uint32_t*)(CONV_BASE + 0x14))
#define CONV_KERNEL     (*(volatile uint32_t*)(CONV_BASE + 0x18))
#define CONV_STATUS     (*(volatile uint32_t*)(CONV_BASE + 0x1C))

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

// Parameters matching hardware specification
#define INPUT_WIDTH     16
#define INPUT_HEIGHT    16
#define NUM_CHANNELS    3
#define KERNEL_SIZE     3
#define OUTPUT_WIDTH    (INPUT_WIDTH - KERNEL_SIZE + 1)   // 14
#define OUTPUT_HEIGHT   (INPUT_HEIGHT - KERNEL_SIZE + 1)  // 14

// Feature map data type (32-bit per element)
typedef int32_t feature_t;

// Test feature map data (16x16x3)
static feature_t feature_map[NUM_CHANNELS][INPUT_HEIGHT][INPUT_WIDTH];

// 3x3 kernels for each channel (32-bit coefficients)
static int32_t kernels[NUM_CHANNELS][KERNEL_SIZE][KERNEL_SIZE];

// Output data (14x14x3)
static feature_t output_sw[NUM_CHANNELS][OUTPUT_HEIGHT][OUTPUT_WIDTH];
static feature_t output_hw[NUM_CHANNELS][OUTPUT_HEIGHT][OUTPUT_WIDTH];

// Initialize test data
void init_test_data(void) {
    // Initialize feature map: channel*1000 + row*16 + col
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int y = 0; y < INPUT_HEIGHT; y++) {
            for (int x = 0; x < INPUT_WIDTH; x++) {
                feature_map[c][y][x] = c * 1000 + y * 16 + x;
            }
        }
    }
    
    // Initialize kernels: identity kernel (center = 1, others = 0)
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int ky = 0; ky < KERNEL_SIZE; ky++) {
            for (int kx = 0; kx < KERNEL_SIZE; kx++) {
                kernels[c][ky][kx] = (ky == 1 && kx == 1) ? 1 : 0;
            }
        }
    }
}

// Software reference convolution for multi-channel
void conv2d_multichan_sw(void) {
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int y = 0; y < OUTPUT_HEIGHT; y++) {
            for (int x = 0; x < OUTPUT_WIDTH; x++) {
                int64_t sum = 0;
                
                // 3x3 convolution
                for (int ky = 0; ky < KERNEL_SIZE; ky++) {
                    for (int kx = 0; kx < KERNEL_SIZE; kx++) {
                        sum += (int64_t)feature_map[c][y + ky][x + kx] * kernels[c][ky][kx];
                    }
                }
                
                // Clamp result to 32-bit
                if (sum < 0) sum = 0;
                if (sum > 0xFFFFFFFF) sum = 0xFFFFFFFF;
                
                output_sw[c][y][x] = (feature_t)sum;
            }
        }
    }
}

// Initialize hardware convolution accelerator
void conv2d_hw_init(void) {
    // Copy feature map to hardware memory
    feature_t* hw_feature = (feature_t*)IMAGE_SRC_ADDR;
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int y = 0; y < INPUT_HEIGHT; y++) {
            for (int x = 0; x < INPUT_WIDTH; x++) {
                hw_feature[c * INPUT_HEIGHT * INPUT_WIDTH + y * INPUT_WIDTH + x] = 
                    feature_map[c][y][x];
            }
        }
    }
    
    // Copy kernels to hardware memory
    int32_t* hw_kernel = (int32_t*)KERNEL_ADDR;
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int ky = 0; ky < KERNEL_SIZE; ky++) {
            for (int kx = 0; kx < KERNEL_SIZE; kx++) {
                hw_kernel[c * 9 + ky * 3 + kx] = kernels[c][ky][kx];
            }
        }
    }
    
    // Configure convolution accelerator
    CONV_SRC_ADDR = IMAGE_SRC_ADDR;
    CONV_DST_ADDR = IMAGE_DST_ADDR;
    CONV_IMG_WIDTH = INPUT_WIDTH;
    CONV_IMG_HEIGHT = INPUT_HEIGHT;
    CONV_CHANNELS = NUM_CHANNELS;
    CONV_KERNEL = KERNEL_ADDR;
}

// Start convolution hardware
void conv2d_hw_start(void) {
    CONV_CTRL = CTRL_ENABLE | CTRL_START;
}

// Wait for convolution to complete
void conv2d_hw_wait(void) {
    while (!(CONV_CTRL & CTRL_DONE)) {
        // Wait
    }
    CONV_CTRL = CTRL_DONE | CTRL_ENABLE;  // Clear done flag
}

// Read hardware results
void conv2d_hw_read_results(void) {
    feature_t* hw_output = (feature_t*)IMAGE_DST_ADDR;
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int y = 0; y < OUTPUT_HEIGHT; y++) {
            for (int x = 0; x < OUTPUT_WIDTH; x++) {
                output_hw[c][y][x] = 
                    hw_output[c * OUTPUT_HEIGHT * OUTPUT_WIDTH + y * OUTPUT_WIDTH + x];
            }
        }
    }
}

// Use DMA to copy data
void dma_copy(uint32_t src, uint32_t dst, uint32_t len) {
    DMA_SRC_ADDR = src;
    DMA_DST_ADDR = dst;
    DMA_XFER_LEN = len;
    DMA_CTRL = CTRL_ENABLE | CTRL_START;
    
    while (!(DMA_CTRL & CTRL_DONE)) {
        // Wait
    }
    DMA_CTRL = CTRL_DONE;  // Clear done flag
}

// Verify results
int verify_results(void) {
    int errors = 0;
    for (int c = 0; c < NUM_CHANNELS; c++) {
        for (int y = 0; y < OUTPUT_HEIGHT; y++) {
            for (int x = 0; x < OUTPUT_WIDTH; x++) {
                if (output_hw[c][y][x] != output_sw[c][y][x]) {
                    errors++;
                }
            }
        }
    }
    return errors;
}

// Main function demonstrating multi-channel convolution with DMA
int main(void) {
    // Initialize test data
    init_test_data();
    
    // Run software reference
    conv2d_multichan_sw();
    
    // Run hardware convolution
    conv2d_hw_init();
    conv2d_hw_start();
    conv2d_hw_wait();
    conv2d_hw_read_results();
    
    // Verify results
    int errors = verify_results();
    
    // Use DMA to copy results to another location
    dma_copy(IMAGE_DST_ADDR, DMA_DST_ADDR, 
             NUM_CHANNELS * OUTPUT_HEIGHT * OUTPUT_WIDTH * sizeof(feature_t));
    
    return errors;
}

/*
 * Hardware Parameters:
 *   - Input:  16×16×3 (768 elements × 4 bytes = 3072 bytes)
 *   - Kernel: 3×3×3 (27 elements × 4 bytes = 108 bytes)
 *   - Output: 14×14×3 (588 elements × 4 bytes = 2352 bytes)
 *   - Total memory required: ~5.5 KB
 *
 * Computation:
 *   - Per output pixel: 9 MACs
 *   - Total MACs: 14×14×3×9 = 5292 MACs
 *
 * Example kernels (3x3):
 *
 * 1. Identity kernel:
 *    { 0, 0, 0 }
 *    { 0, 1, 0 }
 *    { 0, 0, 0 }
 *
 * 2. Edge detection (Sobel horizontal):
 *    { -1,  0,  1 }
 *    { -2,  0,  2 }
 *    { -1,  0,  1 }
 *
 * 3. Edge detection (Sobel vertical):
 *    { -1, -2, -1 }
 *    {  0,  0,  0 }
 *    {  1,  2,  1 }
 *
 * 4. Sharpen:
 *    {  0, -1,  0 }
 *    { -1,  5, -1 }
 *    {  0, -1,  0 }
 *
 * 5. Box blur (average, divide by 9):
 *    { 1, 1, 1 }
 *    { 1, 1, 1 }
 *    { 1, 1, 1 }
 */
