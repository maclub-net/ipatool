#ifndef CSAP_MACHINE_H
#define CSAP_MACHINE_H

#include <stdint.h>
#include <stddef.h>
#include "machimage.h"

#ifdef __cplusplus
extern "C" {
#endif

// 地址常量
#define CSAP_RETURN_ADDRESS  0x0000000100000000ULL
#define CSAP_COREFP_BASE     0x0000100000000000ULL
#define CSAP_COMMERCE_BASE   0x0000100040000000ULL
#define CSAP_KIT_BASE        0x0000100080000000ULL
#define CSAP_SCRATCH_BASE    0x0000300000000000ULL
#define CSAP_SCRATCH_SIZE    (32ULL << 20)
#define CSAP_HEAP_BASE       0x0000400000000000ULL
#define CSAP_HEAP_SIZE       (64ULL << 20)
#define CSAP_STACK_BASE      0x0000500000000000ULL
#define CSAP_STACK_SIZE      (8ULL << 20)
#define CSAP_STACK_END       (CSAP_STACK_BASE + CSAP_STACK_SIZE)
#define CSAP_PAGE_SIZE       0x1000ULL
#define CSAP_MAX_OUTPUT_SIZE (16ULL << 20)

// CoreFP 导出符号名
extern const char* CSAP_CORE_EXPORT_NAMES[6];

// SAP 入口点
typedef struct {
    uint64_t initialize;
    uint64_t exchange;
    uint64_t sign;
    uint64_t teardown;
    uint64_t dispose;
} csap_entry_points_t;

// SAP 机器
typedef struct csap_machine csap_machine_t;

// 额外镜像规格
typedef struct {
    const char* name;
    const uint8_t* data;
    size_t size;
    uint64_t base;
} csap_extra_image_t;

// 额外 shim 别名（返回 0）
typedef struct {
    const char** names;
    int count;
} csap_extra_shims_t;

// 创建机器
// corefp_data, commercecore_data, commercekit_data: 框架二进制数据
// icxs_data: CoreFP.icxs 数据
// extra_images: 额外镜像（可为 NULL）
// extra_image_count: 额外镜像数量
// extra_shims: 额外的返回 0 的 shim 别名（可为 NULL）
csap_machine_t* csap_machine_open_extended(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const csap_extra_image_t* extra_images, int extra_image_count,
    const csap_extra_shims_t* extra_shims);

csap_machine_t* csap_machine_open(const uint8_t* corefp_data, size_t corefp_size,
                                  const uint8_t* commercecore_data, size_t commercecore_size,
                                  const uint8_t* commercekit_data, size_t commercekit_size,
                                  const uint8_t* icxs_data, size_t icxs_size);

// ==================== 内部 API（供 StoreAgent 等使用）====================

// 调用 guest 函数
int csap_machine_invoke(csap_machine_t* m, uint64_t function,
                        const uint64_t* args, int arg_count, uint64_t* out_result);

// Scratch 内存分配
uint64_t csap_machine_scratch(csap_machine_t* m, const uint8_t* data, uint64_t size);
void csap_machine_clear_scratch(csap_machine_t* m);
void csap_machine_begin_call(csap_machine_t* m);

// 读取 guest 内存
uint32_t csap_machine_read_u32(csap_machine_t* m, uint64_t address);
uint64_t csap_machine_read_u64(csap_machine_t* m, uint64_t address);
int csap_machine_read_mem(csap_machine_t* m, uint64_t address, void* buf, uint64_t size);
int csap_machine_write_mem(csap_machine_t* m, uint64_t address, const void* buf, uint64_t size);

// dispose 输出
int csap_machine_dispose(csap_machine_t* m, uint64_t pointer);

// teardown 会话
int csap_machine_teardown(csap_machine_t* m, uint64_t context);

// 初始化 SAP 会话，返回 context value
// hardware_id: 硬件 ID 字节（1-20 字节）
int csap_machine_initialize(csap_machine_t* m,
                            const uint8_t* hardware_id, size_t hardware_id_len,
                            uint64_t* out_context);

// 交换数据
// version: 协议版本
// input: 输入数据
// out_output: 输出数据（调用者负责 free）
// out_result: 结果码
int csap_machine_exchange(csap_machine_t* m,
                          uint32_t version,
                          const uint8_t* hardware_id, size_t hardware_id_len,
                          uint64_t context,
                          const uint8_t* input, size_t input_len,
                          uint8_t** out_output, size_t* out_output_len,
                          int32_t* out_result);

// 签名
int csap_machine_sign(csap_machine_t* m,
                      uint64_t context,
                      const uint8_t* input, size_t input_len,
                      uint8_t** out_output, size_t* out_output_len);

// 销毁
void csap_machine_close(csap_machine_t* m);

#ifdef __cplusplus
}
#endif

#endif // CSAP_MACHINE_H
