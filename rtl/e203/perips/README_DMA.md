# DMA Controller for Hummingbirdv2 E203

## 概述 (Overview)

本文档描述了为 Hummingbirdv2 E203 SoC 设计的简单 DMA 控制器模块。该 DMA 控制器支持内存到内存的数据传输，可用于加速卷积运算等数据密集型操作。

This document describes a simple DMA controller module designed for the Hummingbirdv2 E203 SoC. This DMA controller supports memory-to-memory data transfers and can be used to accelerate data-intensive operations such as convolution.

## 寄存器映射 (Register Map)

| 偏移地址 | 名称      | 访问 | 描述                                        |
|----------|-----------|------|---------------------------------------------|
| 0x00     | CTRL      | R/W  | 控制寄存器 [0]=start, [1]=done(RO), [2]=irq_en |
| 0x04     | SRC_ADDR  | R/W  | 源地址                                      |
| 0x08     | DST_ADDR  | R/W  | 目标地址                                    |
| 0x0C     | LENGTH    | R/W  | 传输长度（32位字数）                        |
| 0x10     | STATUS    | RO   | 状态寄存器 [0]=busy, [1]=done, [2]=error    |

## 使用方法 (Usage)

### C 语言示例 (C Language Example)

```c
#include <stdint.h>

// DMA 基地址 (假设映射到 PPI 区域)
#define DMA_BASE        0x10040000

// 寄存器偏移
#define DMA_CTRL        (*(volatile uint32_t*)(DMA_BASE + 0x00))
#define DMA_SRC_ADDR    (*(volatile uint32_t*)(DMA_BASE + 0x04))
#define DMA_DST_ADDR    (*(volatile uint32_t*)(DMA_BASE + 0x08))
#define DMA_LENGTH      (*(volatile uint32_t*)(DMA_BASE + 0x0C))
#define DMA_STATUS      (*(volatile uint32_t*)(DMA_BASE + 0x10))

// 控制位定义
#define DMA_CTRL_START  (1 << 0)
#define DMA_CTRL_IRQ_EN (1 << 2)

// 状态位定义
#define DMA_STATUS_BUSY  (1 << 0)
#define DMA_STATUS_DONE  (1 << 1)
#define DMA_STATUS_ERROR (1 << 2)

// DMA 传输函数
void dma_transfer(uint32_t src, uint32_t dst, uint32_t len) {
    // 等待 DMA 空闲
    while (DMA_STATUS & DMA_STATUS_BUSY);
    
    // 配置传输参数
    DMA_SRC_ADDR = src;
    DMA_DST_ADDR = dst;
    DMA_LENGTH = len;
    
    // 启动传输
    DMA_CTRL = DMA_CTRL_START;
    
    // 等待传输完成
    while (!(DMA_STATUS & DMA_STATUS_DONE));
}
```

## 简单二维卷积示例 (Simple 2D Convolution Example)

以下是使用 DMA 进行简单 3x3 卷积运算的示例：

```c
#include <stdint.h>

// 输入图像尺寸
#define IMG_WIDTH  8
#define IMG_HEIGHT 8

// 卷积核尺寸
#define KERNEL_SIZE 3

// 输出图像尺寸
#define OUT_WIDTH  (IMG_WIDTH - KERNEL_SIZE + 1)
#define OUT_HEIGHT (IMG_HEIGHT - KERNEL_SIZE + 1)

// 数据缓冲区地址 (DTCM)
#define INPUT_ADDR  0x90000000
#define OUTPUT_ADDR 0x90001000
#define KERNEL_ADDR 0x90002000

// 简单 3x3 边缘检测卷积核
int8_t sobel_kernel[KERNEL_SIZE][KERNEL_SIZE] = {
    {-1, 0, 1},
    {-2, 0, 2},
    {-1, 0, 1}
};

// 2D 卷积计算
void conv2d_3x3(int8_t* input, int8_t* output, int8_t kernel[3][3], 
                int img_w, int img_h) {
    int out_w = img_w - 2;
    int out_h = img_h - 2;
    
    for (int y = 0; y < out_h; y++) {
        for (int x = 0; x < out_w; x++) {
            int32_t sum = 0;
            for (int ky = 0; ky < 3; ky++) {
                for (int kx = 0; kx < 3; kx++) {
                    int idx = (y + ky) * img_w + (x + kx);
                    sum += input[idx] * kernel[ky][kx];
                }
            }
            // 饱和到 int8 范围
            if (sum > 127) sum = 127;
            if (sum < -128) sum = -128;
            output[y * out_w + x] = (int8_t)sum;
        }
    }
}

// 使用 DMA 存储卷积结果到目标寄存器区域
void conv2d_with_dma(void) {
    int8_t* input = (int8_t*)INPUT_ADDR;
    int8_t* output = (int8_t*)OUTPUT_ADDR;
    
    // 执行卷积运算
    conv2d_3x3(input, output, sobel_kernel, IMG_WIDTH, IMG_HEIGHT);
    
    // 使用 DMA 传输结果
    // 计算输出数据大小（以32位字为单位）
    uint32_t output_size = (OUT_WIDTH * OUT_HEIGHT + 3) / 4;
    
    // DMA 传输到目标区域 (例如 FIO 区域的寄存器)
    uint32_t dst_reg_addr = 0xF0000000;  // 目标寄存器地址
    dma_transfer(OUTPUT_ADDR, dst_reg_addr, output_size);
}
```

## 仿真测试 (Simulation Test)

### 使用 iverilog 仿真

1. 编译仿真环境：

```bash
cd vsim
make clean
make install
make compile SIM=iverilog
```

2. 运行 DMA 卷积测试：

```bash
# 使用独立的 DMA 测试台
cd /path/to/e203_hbirdv2/tb
iverilog -o tb_dma_conv2d.vvp \
    -I ../rtl/e203/core/ \
    -I ../rtl/e203/perips/ \
    tb_dma_conv2d.v \
    ../rtl/e203/perips/sirv_dma.v

vvp tb_dma_conv2d.vvp
```

3. 查看波形：

```bash
gtkwave tb_dma_conv2d.vcd
```

## 测试平台说明 (Testbench Description)

测试平台 `tb_dma_conv2d.v` 包含以下功能：

1. **DMA 模块实例化**：实例化 `sirv_dma` 模块
2. **模拟存储器**：提供源数据和目标存储区域
3. **APB 配置任务**：通过 APB 接口配置 DMA
4. **卷积数据生成**：生成测试用的卷积结果数据
5. **传输验证**：验证 DMA 传输的正确性

## 注意事项 (Notes)

1. DMA 传输长度以 32 位字为单位
2. 地址必须 4 字节对齐
3. 传输完成后检查 STATUS 寄存器确认无错误
4. 如需中断通知，设置 CTRL 寄存器的 irq_en 位

## 文件列表 (File List)

- `rtl/e203/perips/sirv_dma.v` - DMA 控制器 Verilog 模块
- `rtl/e203/perips/README_DMA.md` - 本文档
- `tb/tb_dma_conv2d.v` - DMA 卷积测试平台
- `tb/dma_conv2d.h` - C 语言头文件（用于软件集成）
