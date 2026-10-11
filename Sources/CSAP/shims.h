#ifndef CSAP_SHIMS_H
#define CSAP_SHIMS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "unicorn.h"
#include "machimage.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CSAP_SHIM_BASE      0x0000200000000000ULL
#define CSAP_SHIM_CODE_SIZE 0x0000000000080000ULL
#define CSAP_SHIM_SIZE      0x0000000000100000ULL
#define CSAP_SHIM_SLOT_SIZE 16

// 堆和栈地址
#define CSAP_HEAP_BASE      0x0000400000000000ULL
#define CSAP_HEAP_SIZE      (64ULL << 20)
#define CSAP_STACK_BASE     0x0000500000000000ULL
#define CSAP_STACK_SIZE     (8ULL << 20)
#define CSAP_SCRATCH_BASE   0x0000300000000000ULL
#define CSAP_SCRATCH_SIZE   (32ULL << 20)
#define CSAP_RETURN_ADDRESS 0x0000000100000000ULL

#define CSAP_MAX_GUEST_TRANSFER (64ULL << 20)

// 前向声明
typedef struct csap_shims csap_shims_t;

// Shim handler 回调
// 返回 0 表示成功，非 0 表示失败
typedef int (*csap_shim_handler_t)(csap_shims_t* s, void* ctx);

// 创建 shims
// core_exports: CoreFP 镜像的导出符号表（用于解析内部符号）
// icxs: CoreFP.icxs 数据
csap_shims_t* csap_shims_create(csap_uc_engine_t* engine,
                                csap_macho_image_t* corefp_image,
                                const uint8_t* icxs, uint64_t icxs_size);

// 关闭 shims
void csap_shims_close(csap_shims_t* s);

// 解析符号地址（如果不存在，创建一个默认的 "unsupported" shim）
uint64_t csap_shims_resolve(csap_shims_t* s, const char* name);

// 添加一个 shim 函数
uint64_t csap_shims_add_function(csap_shims_t* s, const char* name,
                                 csap_shim_handler_t handler, void* ctx);

// 添加一个 shim 数据块
uint64_t csap_shims_add_data(csap_shims_t* s, const char* name,
                             const void* data, uint64_t size);

// 获取 fault 信息
const char* csap_shims_fault(csap_shims_t* s);
void csap_shims_reset_fault(csap_shims_t* s);

// ==================== 辅助函数 ====================

// 读取函数参数（System V AMD64 ABI）
// index 0-5: RDI, RSI, RDX, RCX, R8, R9
// index >= 6: 栈
int csap_shims_arg(csap_shims_t* s, int index, uint64_t* value);

// 设置返回值 (RAX)
int csap_shims_set_result(csap_shims_t* s, uint64_t value);

// 内存读写辅助
int csap_shims_read_u32(csap_shims_t* s, uint64_t addr, uint32_t* value);
int csap_shims_write_u32(csap_shims_t* s, uint64_t addr, uint32_t value);
int csap_shims_read_u64(csap_shims_t* s, uint64_t addr, uint64_t* value);
int csap_shims_write_u64(csap_shims_t* s, uint64_t addr, uint64_t value);
int csap_shims_read_mem(csap_shims_t* s, uint64_t addr, void* buf, uint64_t size);
int csap_shims_write_mem(csap_shims_t* s, uint64_t addr, const void* buf, uint64_t size);

// 读取 C 字符串（最多 max_len 字节）
int csap_shims_read_cstring(csap_shims_t* s, uint64_t addr, char* buf, size_t max_len);

// 获取 errno
uint64_t csap_shims_errno(csap_shims_t* s);
void csap_shims_set_errno(csap_shims_t* s, uint64_t value);

// 获取 engine
csap_uc_engine_t* csap_shims_engine(csap_shims_t* s);

// 平台服务状态访问
uint64_t csap_shims_errno_addr(csap_shims_t* s);
void csap_shims_set_errno_addr(csap_shims_t* s, uint64_t addr);
uint64_t csap_shims_icxs_offset(csap_shims_t* s);
void csap_shims_set_icxs_offset(csap_shims_t* s, uint64_t offset);
uint32_t csap_shims_iterator(csap_shims_t* s);
void csap_shims_set_iterator(csap_shims_t* s, uint32_t iter);
const uint8_t* csap_shims_icxs(csap_shims_t* s);
uint64_t csap_shims_icxs_size(csap_shims_t* s);
csap_macho_image_t* csap_shims_corefp(csap_shims_t* s);

// ==================== 堆管理 ====================

uint64_t csap_shims_allocate(csap_shims_t* s, uint64_t size);
int csap_shims_release(csap_shims_t* s, uint64_t address);
uint64_t csap_shims_allocation_size(csap_shims_t* s, uint64_t address);

// ==================== 服务注册 ====================

// 注册内存服务 (malloc, free, memcpy, etc.)
int csap_shims_register_memory_services(csap_shims_t* s);

// 注册平台服务 (CoreFoundation, IOKit, POSIX, etc.)
int csap_shims_register_platform_services(csap_shims_t* s);

#ifdef __cplusplus
}
#endif

#endif // CSAP_SHIMS_H
