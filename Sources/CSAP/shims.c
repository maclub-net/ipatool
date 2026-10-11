#include "shims.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ==================== 内部数据结构 ====================

typedef struct {
    char* name;
    csap_shim_handler_t handler;
    void* ctx;
} csap_shim_entry_t;

typedef struct {
    char* name;
    uint64_t address;
} csap_symbol_entry_t;

typedef struct {
    uint64_t address;
    uint64_t size;
    uint64_t reserved;
} csap_allocation_t;

typedef struct {
    uint64_t address;
    uint64_t size;
} csap_free_block_t;

struct csap_shims {
    csap_uc_engine_t* engine;
    csap_uc_hook_t hook;

    csap_shim_entry_t* entries;
    uint32_t entry_count;
    uint32_t entry_cap;

    csap_symbol_entry_t* symbols;
    uint32_t symbol_count;
    uint32_t symbol_cap;

    uint64_t code_cursor;
    uint64_t data_cursor;

    char* fault;

    csap_macho_image_t* corefp;
    uint8_t* icxs;
    uint64_t icxs_size;

    uint64_t errno_val;

    // 堆管理
    uint64_t heap_cursor;
    csap_allocation_t* allocations;
    uint32_t allocation_count;
    uint32_t allocation_cap;
    csap_free_block_t* free_blocks;
    uint32_t free_block_count;
    uint32_t free_block_cap;

    // 平台服务状态
    uint64_t errno_addr;
    uint64_t icxs_offset;
    uint32_t iterator;
};

// ==================== 符号表查找 ====================

static uint64_t find_symbol(csap_shims_t* s, const char* name) {
    for (uint32_t i = 0; i < s->symbol_count; i++) {
        if (strcmp(s->symbols[i].name, name) == 0) {
            return s->symbols[i].address;
        }
    }
    return 0;
}

static void add_symbol(csap_shims_t* s, const char* name, uint64_t address) {
    for (uint32_t i = 0; i < s->symbol_count; i++) {
        if (strcmp(s->symbols[i].name, name) == 0) return;
    }
    if (s->symbol_count >= s->symbol_cap) {
        s->symbol_cap = s->symbol_cap ? s->symbol_cap * 2 : 64;
        s->symbols = realloc(s->symbols, s->symbol_cap * sizeof(csap_symbol_entry_t));
    }
    s->symbols[s->symbol_count].name = strdup(name);
    s->symbols[s->symbol_count].address = address;
    s->symbol_count++;
}

// ==================== Shim 条目 ====================

static csap_shim_entry_t* find_entry(csap_shims_t* s, uint64_t address) {
    for (uint32_t i = 0; i < s->entry_count; i++) {
        // 每个 entry 占一个 slot，地址 = shimBase + i * slotSize
        // 但我们直接比较地址
        if (s->symbols && i < s->symbol_count) {
            // 实际上 entries 是按地址查找的
        }
    }
    // 重新实现：遍历 symbols 找到地址对应的 entry
    for (uint32_t i = 0; i < s->symbol_count; i++) {
        if (s->symbols[i].address == address) {
            // 找到对应的 entry
            for (uint32_t j = 0; j < s->entry_count; j++) {
                if (strcmp(s->entries[j].name, s->symbols[i].name) == 0) {
                    return &s->entries[j];
                }
            }
        }
    }
    return NULL;
}

static void add_entry(csap_shims_t* s, const char* name,
                      csap_shim_handler_t handler, void* ctx) {
    for (uint32_t i = 0; i < s->entry_count; i++) {
        if (strcmp(s->entries[i].name, name) == 0) return;
    }
    if (s->entry_count >= s->entry_cap) {
        s->entry_cap = s->entry_cap ? s->entry_cap * 2 : 64;
        s->entries = realloc(s->entries, s->entry_cap * sizeof(csap_shim_entry_t));
    }
    s->entries[s->entry_count].name = strdup(name);
    s->entries[s->entry_count].handler = handler;
    s->entries[s->entry_count].ctx = ctx;
    s->entry_count++;
}

// ==================== Dispatch hook ====================

static void shim_dispatch(csap_uc_engine_t* uc, uint64_t address, uint32_t size, void* user_data) {
    (void)uc;
    (void)size;
    csap_shims_t* s = (csap_shims_t*)user_data;

    csap_shim_entry_t* entry = find_entry(s, address);
    if (entry == NULL) {
        char buf[128];
        snprintf(buf, sizeof(buf), "guest entered unknown service address 0x%llx",
                 (unsigned long long)address);
        if (s->fault == NULL) s->fault = strdup(buf);
        csap_uc_emu_stop(uc);
        return;
    }

    if (entry->handler != NULL) {
        int ret = entry->handler(s, entry->ctx);
        if (ret != 0 && s->fault == NULL) {
            char buf[256];
            snprintf(buf, sizeof(buf), "%s: handler failed", entry->name);
            s->fault = strdup(buf);
            csap_uc_emu_stop(uc);
        }
    }
}

// ==================== 默认 unsupported handler ====================

static int unsupported_handler(csap_shims_t* s, void* ctx) {
    (void)s;
    const char* name = (const char*)ctx;
    fprintf(stderr, "csap: guest called unsupported import %s\n", name);
    return -1;
}

// ==================== 公开 API ====================

csap_shims_t* csap_shims_create(csap_uc_engine_t* engine,
                                csap_macho_image_t* corefp_image,
                                const uint8_t* icxs, uint64_t icxs_size) {
    if (engine == NULL) return NULL;

    // 映射 shim 区域
    if (csap_uc_mem_map(engine, CSAP_SHIM_BASE, CSAP_SHIM_SIZE, CSAP_UC_PROT_ALL) != 0) {
        fprintf(stderr, "csap: failed to map shim area\n");
        return NULL;
    }

    csap_shims_t* s = calloc(1, sizeof(csap_shims_t));
    if (s == NULL) return NULL;

    s->engine = engine;
    s->code_cursor = CSAP_SHIM_BASE;
    s->data_cursor = CSAP_SHIM_BASE + CSAP_SHIM_CODE_SIZE;
    s->corefp = corefp_image;

    if (icxs != NULL && icxs_size > 0) {
        s->icxs = malloc(icxs_size);
        if (s->icxs) {
            memcpy(s->icxs, icxs, icxs_size);
            s->icxs_size = icxs_size;
        }
    }

    // 注册代码 hook
    {
        int ret = csap_uc_hook_add(engine, &s->hook, CSAP_UC_HOOK_CODE,
                                   shim_dispatch, s,
                                   CSAP_SHIM_BASE, CSAP_SHIM_BASE + CSAP_SHIM_CODE_SIZE - 1);
        if (ret != 0) {
            fprintf(stderr, "csap: failed to add shim hook: %s (code %d)\n",
                    csap_uc_strerror(ret), ret);
            free(s->icxs);
            free(s);
            return NULL;
        }
    }

    // 注册内存服务
    if (csap_shims_register_memory_services(s) != 0) {
        fprintf(stderr, "csap: failed to register memory services\n");
        csap_uc_hook_del(engine, s->hook);
        free(s->icxs);
        free(s);
        return NULL;
    }

    // 注册平台服务
    if (csap_shims_register_platform_services(s) != 0) {
        fprintf(stderr, "csap: failed to register platform services\n");
        csap_uc_hook_del(engine, s->hook);
        free(s->icxs);
        free(s);
        return NULL;
    }

    return s;
}

void csap_shims_close(csap_shims_t* s) {
    if (s == NULL) return;

    if (s->hook != 0) {
        csap_uc_hook_del(s->engine, s->hook);
    }

    for (uint32_t i = 0; i < s->entry_count; i++) {
        free(s->entries[i].name);
    }
    free(s->entries);

    for (uint32_t i = 0; i < s->symbol_count; i++) {
        free(s->symbols[i].name);
    }
    free(s->symbols);

    free(s->fault);
    free(s->icxs);
    free(s->allocations);
    free(s->free_blocks);
    free(s);
}

uint64_t csap_shims_resolve(csap_shims_t* s, const char* name) {
    if (s == NULL || name == NULL) return 0;

    uint64_t addr = find_symbol(s, name);
    if (addr != 0) return addr;

    return csap_shims_add_function(s, name, unsupported_handler, (void*)name);
}

uint64_t csap_shims_add_function(csap_shims_t* s, const char* name,
                                 csap_shim_handler_t handler, void* ctx) {
    if (s == NULL || name == NULL) return 0;

    uint64_t existing = find_symbol(s, name);
    if (existing != 0) return existing;

    if (s->code_cursor + CSAP_SHIM_SLOT_SIZE > CSAP_SHIM_BASE + CSAP_SHIM_CODE_SIZE) {
        fprintf(stderr, "csap: shim code area is full\n");
        return 0;
    }

    uint64_t address = s->code_cursor;
    s->code_cursor += CSAP_SHIM_SLOT_SIZE;

    // 写入 ret 指令
    uint8_t ret = 0xC3;
    if (csap_uc_mem_write(s->engine, address, &ret, 1) != 0) {
        fprintf(stderr, "csap: failed to write shim stub for %s\n", name);
        return 0;
    }

    add_entry(s, name, handler, ctx);
    add_symbol(s, name, address);

    return address;
}

uint64_t csap_shims_add_data(csap_shims_t* s, const char* name,
                             const void* data, uint64_t size) {
    if (s == NULL || name == NULL) return 0;

    uint64_t existing = find_symbol(s, name);
    if (existing != 0) return existing;

    // 8 字节对齐
    s->data_cursor = (s->data_cursor + 7) & ~7ULL;
    if (s->data_cursor + size > CSAP_SHIM_BASE + CSAP_SHIM_SIZE) {
        fprintf(stderr, "csap: shim data area is full\n");
        return 0;
    }

    uint64_t address = s->data_cursor;
    s->data_cursor += size > 8 ? size : 8;

    if (data != NULL && size > 0) {
        if (csap_uc_mem_write(s->engine, address, data, size) != 0) {
            fprintf(stderr, "csap: failed to write shim data for %s\n", name);
            return 0;
        }
    }

    add_symbol(s, name, address);
    return address;
}

const char* csap_shims_fault(csap_shims_t* s) {
    return s ? s->fault : NULL;
}

void csap_shims_reset_fault(csap_shims_t* s) {
    if (s == NULL) return;
    free(s->fault);
    s->fault = NULL;
}

// ==================== 辅助函数 ====================

int csap_shims_arg(csap_shims_t* s, int index, uint64_t* value) {
    if (s == NULL || value == NULL) return -1;

    static const int32_t regs[] = {
        CSAP_REG_RDI, CSAP_REG_RSI, CSAP_REG_RDX,
        CSAP_REG_RCX, CSAP_REG_R8,  CSAP_REG_R9
    };
    const int reg_count = (int)(sizeof(regs) / sizeof(regs[0]));

    if (index >= 0 && index < reg_count) {
        return csap_uc_reg_read(s->engine, regs[index], value);
    }

    if (index < 0) return -1;

    // 从栈读取
    uint64_t rsp;
    if (csap_uc_reg_read(s->engine, CSAP_REG_RSP, &rsp) != 0) return -1;

    // 返回地址占 8 字节，然后是第 7 个及以后的参数
    uint64_t stack_off = 8 + (uint64_t)(index - reg_count) * 8;
    return csap_uc_mem_read(s->engine, rsp + stack_off, value, 8);
}

int csap_shims_set_result(csap_shims_t* s, uint64_t value) {
    if (s == NULL) return -1;
    return csap_uc_reg_write(s->engine, CSAP_REG_RAX, value);
}

int csap_shims_read_u32(csap_shims_t* s, uint64_t addr, uint32_t* value) {
    uint8_t buf[4];
    if (csap_uc_mem_read(s->engine, addr, buf, 4) != 0) return -1;
    *value = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) |
             ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
    return 0;
}

int csap_shims_write_u32(csap_shims_t* s, uint64_t addr, uint32_t value) {
    uint8_t buf[4] = {
        (uint8_t)(value), (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24)
    };
    return csap_uc_mem_write(s->engine, addr, buf, 4);
}

int csap_shims_read_u64(csap_shims_t* s, uint64_t addr, uint64_t* value) {
    uint8_t buf[8];
    if (csap_uc_mem_read(s->engine, addr, buf, 8) != 0) return -1;
    *value = 0;
    for (int i = 0; i < 8; i++) {
        *value |= ((uint64_t)buf[i]) << (i * 8);
    }
    return 0;
}

int csap_shims_write_u64(csap_shims_t* s, uint64_t addr, uint64_t value) {
    uint8_t buf[8];
    for (int i = 0; i < 8; i++) {
        buf[i] = (uint8_t)(value >> (i * 8));
    }
    return csap_uc_mem_write(s->engine, addr, buf, 8);
}

int csap_shims_read_mem(csap_shims_t* s, uint64_t addr, void* buf, uint64_t size) {
    return csap_uc_mem_read(s->engine, addr, buf, size);
}

int csap_shims_write_mem(csap_shims_t* s, uint64_t addr, const void* buf, uint64_t size) {
    return csap_uc_mem_write(s->engine, addr, buf, size);
}

int csap_shims_read_cstring(csap_shims_t* s, uint64_t addr, char* buf, size_t max_len) {
    if (s == NULL || buf == NULL || max_len == 0) return -1;

    size_t i = 0;
    while (i < max_len - 1) {
        uint8_t ch;
        if (csap_uc_mem_read(s->engine, addr + i, &ch, 1) != 0) return -1;
        if (ch == 0) {
            buf[i] = '\0';
            return 0;
        }
        buf[i] = (char)ch;
        i++;
    }
    buf[max_len - 1] = '\0';
    return 0;
}

uint64_t csap_shims_errno(csap_shims_t* s) {
    return s ? s->errno_val : 0;
}

void csap_shims_set_errno(csap_shims_t* s, uint64_t value) {
    if (s) s->errno_val = value;
}

csap_uc_engine_t* csap_shims_engine(csap_shims_t* s) {
    return s ? s->engine : NULL;
}

uint64_t csap_shims_errno_addr(csap_shims_t* s) {
    return s ? s->errno_addr : 0;
}

void csap_shims_set_errno_addr(csap_shims_t* s, uint64_t addr) {
    if (s) s->errno_addr = addr;
}

uint64_t csap_shims_icxs_offset(csap_shims_t* s) {
    return s ? s->icxs_offset : 0;
}

void csap_shims_set_icxs_offset(csap_shims_t* s, uint64_t offset) {
    if (s) s->icxs_offset = offset;
}

uint32_t csap_shims_iterator(csap_shims_t* s) {
    return s ? s->iterator : 0;
}

void csap_shims_set_iterator(csap_shims_t* s, uint32_t iter) {
    if (s) s->iterator = iter;
}

const uint8_t* csap_shims_icxs(csap_shims_t* s) {
    return s ? s->icxs : NULL;
}

uint64_t csap_shims_icxs_size(csap_shims_t* s) {
    return s ? s->icxs_size : 0;
}

csap_macho_image_t* csap_shims_corefp(csap_shims_t* s) {
    return s ? s->corefp : NULL;
}

// ==================== 堆管理 ====================

static uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static void coalesce_free_blocks(csap_shims_t* s) {
    // 按地址排序
    for (uint32_t i = 0; i < s->free_block_count; i++) {
        for (uint32_t j = i + 1; j < s->free_block_count; j++) {
            if (s->free_blocks[j].address < s->free_blocks[i].address) {
                csap_free_block_t tmp = s->free_blocks[i];
                s->free_blocks[i] = s->free_blocks[j];
                s->free_blocks[j] = tmp;
            }
        }
    }

    // 合并相邻块
    uint32_t write = 0;
    for (uint32_t i = 0; i < s->free_block_count; i++) {
        if (write > 0) {
            csap_free_block_t* last = &s->free_blocks[write - 1];
            if (last->address + last->size == s->free_blocks[i].address) {
                last->size += s->free_blocks[i].size;
                continue;
            }
        }
        s->free_blocks[write++] = s->free_blocks[i];
    }
    s->free_block_count = write;

    // 回收堆末尾的空闲块
    while (s->free_block_count > 0) {
        csap_free_block_t* last = &s->free_blocks[s->free_block_count - 1];
        if (last->address + last->size != CSAP_HEAP_BASE + s->heap_cursor) break;
        s->heap_cursor -= last->size;
        s->free_block_count--;
    }
}

uint64_t csap_shims_allocate(csap_shims_t* s, uint64_t size) {
    if (s == NULL) return 0;
    if (size > CSAP_MAX_GUEST_TRANSFER) return 0;

    uint64_t reserved = align_up(size > 0 ? size : 1, 16);

    // 尝试从空闲块分配
    for (uint32_t i = 0; i < s->free_block_count; i++) {
        if (s->free_blocks[i].size < reserved) continue;

        uint64_t address = s->free_blocks[i].address;
        if (s->free_blocks[i].size == reserved) {
            // 移除这个块
            for (uint32_t j = i; j < s->free_block_count - 1; j++) {
                s->free_blocks[j] = s->free_blocks[j + 1];
            }
            s->free_block_count--;
        } else {
            s->free_blocks[i].address += reserved;
            s->free_blocks[i].size -= reserved;
        }

        // 记录分配
        if (s->allocation_count >= s->allocation_cap) {
            s->allocation_cap = s->allocation_cap ? s->allocation_cap * 2 : 64;
            s->allocations = realloc(s->allocations, s->allocation_cap * sizeof(csap_allocation_t));
        }
        s->allocations[s->allocation_count].address = address;
        s->allocations[s->allocation_count].size = size;
        s->allocations[s->allocation_count].reserved = reserved;
        s->allocation_count++;

        return address;
    }

    // 从堆顶分配
    if (s->heap_cursor > CSAP_HEAP_SIZE || reserved > CSAP_HEAP_SIZE - s->heap_cursor) {
        return 0;  // 堆耗尽
    }

    uint64_t address = CSAP_HEAP_BASE + s->heap_cursor;
    s->heap_cursor += reserved;

    if (s->allocation_count >= s->allocation_cap) {
        s->allocation_cap = s->allocation_cap ? s->allocation_cap * 2 : 64;
        s->allocations = realloc(s->allocations, s->allocation_cap * sizeof(csap_allocation_t));
    }
    s->allocations[s->allocation_count].address = address;
    s->allocations[s->allocation_count].size = size;
    s->allocations[s->allocation_count].reserved = reserved;
    s->allocation_count++;

    return address;
}

int csap_shims_release(csap_shims_t* s, uint64_t address) {
    if (s == NULL || address == 0) return -1;

    // 查找分配记录
    int found = -1;
    for (uint32_t i = 0; i < s->allocation_count; i++) {
        if (s->allocations[i].address == address) {
            found = (int)i;
            break;
        }
    }
    if (found < 0) return -1;

    uint64_t reserved = s->allocations[found].reserved;

    // 清零内存
    uint8_t zero = 0;
    for (uint64_t i = 0; i < reserved; i++) {
        csap_uc_mem_write(s->engine, address + i, &zero, 1);
    }

    // 移除分配记录
    for (uint32_t i = (uint32_t)found; i < s->allocation_count - 1; i++) {
        s->allocations[i] = s->allocations[i + 1];
    }
    s->allocation_count--;

    // 添加到空闲块
    if (s->free_block_count >= s->free_block_cap) {
        s->free_block_cap = s->free_block_cap ? s->free_block_cap * 2 : 64;
        s->free_blocks = realloc(s->free_blocks, s->free_block_cap * sizeof(csap_free_block_t));
    }
    s->free_blocks[s->free_block_count].address = address;
    s->free_blocks[s->free_block_count].size = reserved;
    s->free_block_count++;

    coalesce_free_blocks(s);
    return 0;
}

uint64_t csap_shims_allocation_size(csap_shims_t* s, uint64_t address) {
    if (s == NULL) return 0;
    for (uint32_t i = 0; i < s->allocation_count; i++) {
        if (s->allocations[i].address == address) {
            return s->allocations[i].reserved;
        }
    }
    return 0;
}
