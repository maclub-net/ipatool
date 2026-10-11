#include "machine.h"
#include "shims.h"
#include "unicorn.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

const char* CSAP_CORE_EXPORT_NAMES[6] = {
    "_WIn9UJ86JKdV4dM",
    "_X46O5IeS",
    "_YlCJ3lg",
    "_dku592fbFAj",
    "_fdjkDSAFjklaf2s",
    "_lxpgvVMLd0S7uRl",
};

struct csap_machine {
    csap_uc_engine_t* engine;
    csap_shims_t* services;
    csap_entry_points_t entry;
    uint64_t scratch_cursor;
    int closed;

    // 镜像
    csap_macho_image_t* corefp;
    csap_macho_image_t* commerce_core;
    csap_macho_image_t* commerce_kit;
    csap_macho_image_t** extra_images;
    int extra_image_count;
};

static uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

// 硬件 ID 块：4字节长度 + 硬件ID（最多20字节），总共24字节
static int make_hardware_block(const uint8_t* hardware_id, size_t len, uint8_t* out) {
    if (len == 0 || len > 20) return -1;
    memset(out, 0, 24);
    uint32_t le_len = (uint32_t)len;
    out[0] = (uint8_t)(le_len & 0xFF);
    out[1] = (uint8_t)((le_len >> 8) & 0xFF);
    out[2] = (uint8_t)((le_len >> 16) & 0xFF);
    out[3] = (uint8_t)((le_len >> 24) & 0xFF);
    memcpy(out + 4, hardware_id, len);
    return 0;
}

// 符号解析器：先查已知导出，再查 shims
typedef struct {
    csap_machine_t* machine;
    // 简单导出表
    const char** names;
    uint64_t* addresses;
    int count;
    int cap;
} csap_resolver_t;

static int resolver_resolve(const char* name, uint64_t* address, void* ctx) {
    csap_resolver_t* r = (csap_resolver_t*)ctx;
    for (int i = 0; i < r->count; i++) {
        if (strcmp(r->names[i], name) == 0) {
            *address = r->addresses[i];
            return 0;
        }
    }
    // 回退到 shims（会创建 unsupported stub）
    *address = csap_shims_resolve(r->machine->services, name);
    return 0;
}

// 内存操作回调（适配 csap_macho_load）
static int mem_map_cb(uint64_t address, uint64_t size, void* ctx) {
    return csap_uc_mem_map((csap_uc_engine_t*)ctx, address, size, CSAP_UC_PROT_ALL);
}

static int mem_write_cb(uint64_t address, const void* data, uint64_t size, void* ctx) {
    return csap_uc_mem_write((csap_uc_engine_t*)ctx, address, data, size);
}

static int return_zero_handler(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, 0);
}

static void resolver_add(csap_resolver_t* r, const char* name, uint64_t addr) {
    if (r->count >= r->cap) {
        r->cap = r->cap ? r->cap * 2 : 64;
        r->names = realloc(r->names, r->cap * sizeof(char*));
        r->addresses = realloc(r->addresses, r->cap * sizeof(uint64_t));
    }
    r->names[r->count] = strdup(name);
    r->addresses[r->count] = addr;
    r->count++;
}

// ==================== Scratch 内存 ====================

uint64_t csap_machine_scratch(csap_machine_t* m, const uint8_t* data, uint64_t size) {
    uint64_t reserved = align_up(size > 0 ? size : 1, 16);
    if (m->scratch_cursor > CSAP_SCRATCH_SIZE ||
        reserved > CSAP_SCRATCH_SIZE - m->scratch_cursor) {
        fprintf(stderr, "csap: scratch space exhausted\n");
        return 0;
    }

    uint64_t address = CSAP_SCRATCH_BASE + m->scratch_cursor;
    m->scratch_cursor += reserved;

    if (data != NULL && size > 0) {
        if (csap_uc_mem_write(m->engine, address, data, size) != 0) {
            fprintf(stderr, "csap: failed to write scratch data\n");
            return 0;
        }
    } else if (size > 0) {
        // 清零
        uint8_t* zero = calloc(1, size);
        if (zero == NULL) return 0;
        csap_uc_mem_write(m->engine, address, zero, size);
        free(zero);
    }
    return address;
}

void csap_machine_clear_scratch(csap_machine_t* m) {
    if (m->scratch_cursor != 0 && m->engine != NULL && !m->closed) {
        uint8_t* zero = calloc(1, m->scratch_cursor);
        if (zero) {
            csap_uc_mem_write(m->engine, CSAP_SCRATCH_BASE, zero, m->scratch_cursor);
            free(zero);
        }
    }
    m->scratch_cursor = 0;
}

uint64_t csap_machine_read_u64(csap_machine_t* m, uint64_t address) {
    uint8_t buf[8];
    if (csap_uc_mem_read(m->engine, address, buf, 8) != 0) return 0;
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= ((uint64_t)buf[i]) << (i * 8);
    return value;
}

uint32_t csap_machine_read_u32(csap_machine_t* m, uint64_t address) {
    uint8_t buf[4];
    if (csap_uc_mem_read(m->engine, address, buf, 4) != 0) return 0;
    return (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) |
           ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
}

static int machine_write_u64(csap_machine_t* m, uint64_t address, uint64_t value) {
    uint8_t buf[8];
    for (int i = 0; i < 8; i++) buf[i] = (uint8_t)(value >> (i * 8));
    return csap_uc_mem_write(m->engine, address, buf, 8);
}

void csap_machine_begin_call(csap_machine_t* m) {
    if (m) m->scratch_cursor = 0;
}

int csap_machine_read_mem(csap_machine_t* m, uint64_t address, void* buf, uint64_t size) {
    if (m == NULL || buf == NULL) return -1;
    return csap_uc_mem_read(m->engine, address, buf, size);
}

int csap_machine_write_mem(csap_machine_t* m, uint64_t address, const void* buf, uint64_t size) {
    if (m == NULL || buf == NULL) return -1;
    return csap_uc_mem_write(m->engine, address, buf, size);
}

int csap_machine_dispose(csap_machine_t* m, uint64_t pointer) {
    if (m == NULL || pointer == 0) return 0;
    uint64_t args[1] = {pointer};
    uint64_t status;
    return csap_machine_invoke(m, m->entry.dispose, args, 1, &status);
}

int csap_machine_teardown(csap_machine_t* m, uint64_t context) {
    if (m == NULL || context == 0) return 0;
    uint64_t args[1] = {context};
    uint64_t status;
    if (csap_machine_invoke(m, m->entry.teardown, args, 1, &status) != 0) return -1;
    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: teardown returned %d\n", (int32_t)status);
        return -1;
    }
    return 0;
}

// ==================== Invoke ====================

int csap_machine_invoke(csap_machine_t* m, uint64_t function,
                        const uint64_t* args, int arg_count, uint64_t* out_result) {
    if (m->closed) {
        fprintf(stderr, "csap: machine is closed\n");
        return -1;
    }
    if (function == 0) {
        fprintf(stderr, "csap: entry point unavailable\n");
        return -1;
    }

    int registers[] = {CSAP_REG_RDI, CSAP_REG_RSI, CSAP_REG_RDX,
                       CSAP_REG_RCX, CSAP_REG_R8, CSAP_REG_R9};
    int reg_count = 6;

    for (int i = 0; i < reg_count; i++) {
        uint64_t value = (i < arg_count) ? args[i] : 0;
        if (csap_uc_reg_write(m->engine, registers[i], value) != 0) {
            fprintf(stderr, "csap: failed to write argument register\n");
            return -1;
        }
    }

    int extra = arg_count > reg_count ? arg_count - reg_count : 0;

    uint64_t sp = CSAP_STACK_END - (uint64_t)(extra + 1) * 8;
    if (sp % 16 != 8) sp -= 8;

    if (machine_write_u64(m, sp, CSAP_RETURN_ADDRESS) != 0) {
        fprintf(stderr, "csap: failed to write return address\n");
        return -1;
    }

    for (int i = 0; i < extra; i++) {
        if (machine_write_u64(m, sp + 8 + (uint64_t)i * 8, args[reg_count + i]) != 0) {
            fprintf(stderr, "csap: failed to write stack argument\n");
            return -1;
        }
    }

    if (csap_uc_reg_write(m->engine, CSAP_REG_RSP, sp) != 0) {
        fprintf(stderr, "csap: failed to write stack pointer\n");
        return -1;
    }

    csap_shims_reset_fault(m->services);

    // 超时 60 秒
    if (csap_uc_emu_start(m->engine, function, CSAP_RETURN_ADDRESS, 60 * 1000 * 1000, 0) != 0) {
        const char* fault = csap_shims_fault(m->services);
        if (fault) {
            fprintf(stderr, "csap: shim fault: %s\n", fault);
            return -1;
        }
        fprintf(stderr, "csap: emu_start failed\n");
        return -1;
    }

    const char* fault = csap_shims_fault(m->services);
    if (fault) {
        fprintf(stderr, "csap: shim fault after start: %s\n", fault);
        return -1;
    }

    uint64_t rip;
    if (csap_uc_reg_read(m->engine, CSAP_REG_RIP, &rip) != 0) {
        fprintf(stderr, "csap: failed to read RIP\n");
        return -1;
    }
    if (rip != CSAP_RETURN_ADDRESS) {
        fprintf(stderr, "csap: guest stopped unexpectedly at 0x%llx\n",
                (unsigned long long)rip);
        return -1;
    }

    uint64_t result;
    if (csap_uc_reg_read(m->engine, CSAP_REG_RAX, &result) != 0) {
        fprintf(stderr, "csap: failed to read RAX\n");
        return -1;
    }

    if (out_result) *out_result = result;
    return 0;
}

// ==================== Open ====================

csap_machine_t* csap_machine_open_extended(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const csap_extra_image_t* extra_images, int extra_image_count,
    const csap_extra_shims_t* extra_shims) {
    if (corefp_data == NULL || commercecore_data == NULL || commercekit_data == NULL) {
        return NULL;
    }

    csap_machine_t* m = calloc(1, sizeof(csap_machine_t));
    if (m == NULL) return NULL;

    // 额外镜像数组
    csap_macho_image_t** extra = NULL;
    if (extra_image_count > 0) {
        extra = calloc(extra_image_count, sizeof(csap_macho_image_t*));
        if (extra == NULL) { free(m); return NULL; }
    }

    // 打开镜像
    m->corefp = csap_macho_open("CoreFP", corefp_data, corefp_size);
    if (m->corefp == NULL) { fprintf(stderr, "csap: open CoreFP failed\n"); goto fail; }

    m->commerce_core = csap_macho_open("CommerceCore", commercecore_data, commercecore_size);
    if (m->commerce_core == NULL) { fprintf(stderr, "csap: open CommerceCore failed\n"); goto fail; }

    m->commerce_kit = csap_macho_open("CommerceKit", commercekit_data, commercekit_size);
    if (m->commerce_kit == NULL) { fprintf(stderr, "csap: open CommerceKit failed\n"); goto fail; }

    // 打开额外镜像
    m->extra_images = extra;
    m->extra_image_count = extra_image_count;
    for (int i = 0; i < extra_image_count; i++) {
        extra[i] = csap_macho_open(extra_images[i].name, extra_images[i].data, extra_images[i].size);
        if (extra[i] == NULL) {
            fprintf(stderr, "csap: open extra image %s failed\n", extra_images[i].name);
            goto fail;
        }
    }

    // 解析导出符号
    csap_resolver_t resolver = {0};
    resolver.machine = m;

    // CoreFP 导出
    for (int i = 0; i < 6; i++) {
        uint64_t addr = 0;
        if (csap_macho_export(m->corefp, CSAP_CORE_EXPORT_NAMES[i], CSAP_COREFP_BASE, &addr) != 0) {
            fprintf(stderr, "csap: resolve CoreFP export %s failed\n", CSAP_CORE_EXPORT_NAMES[i]);
            goto fail;
        }
        resolver_add(&resolver, CSAP_CORE_EXPORT_NAMES[i], addr);
    }

    // CommerceCore: _get_mac_address
    {
        uint64_t addr = 0;
        if (csap_macho_export(m->commerce_core, "_get_mac_address", CSAP_COMMERCE_BASE, &addr) != 0) {
            fprintf(stderr, "csap: resolve _get_mac_address failed\n");
            goto fail;
        }
        resolver_add(&resolver, "_get_mac_address", addr);
    }

    // CommerceKit 入口点
    const char* entry_names[] = {"_cp2g1b9ro", "_Mib5yocT", "_Fc3vhtJDvr", "_IPaI1oem5iL", "_jEHf8Xzsv8K"};
    uint64_t entry_addrs[5] = {0};
    for (int i = 0; i < 5; i++) {
        if (csap_macho_export(m->commerce_kit, entry_names[i], CSAP_KIT_BASE, &entry_addrs[i]) != 0) {
            fprintf(stderr, "csap: resolve CommerceKit export %s failed\n", entry_names[i]);
            goto fail;
        }
        resolver_add(&resolver, entry_names[i], entry_addrs[i]);
    }

    m->entry.initialize = entry_addrs[0];
    m->entry.exchange   = entry_addrs[1];
    m->entry.sign       = entry_addrs[2];
    m->entry.teardown   = entry_addrs[3];
    m->entry.dispose    = entry_addrs[4];

    // 创建 Unicorn 引擎
    m->engine = csap_uc_open(CSAP_UC_ARCH_X86, CSAP_UC_MODE_64);
    if (m->engine == NULL) {
        fprintf(stderr, "csap: failed to create Unicorn engine\n");
        goto fail;
    }

    // 映射内存区域
    if (csap_uc_mem_map(m->engine, CSAP_RETURN_ADDRESS, CSAP_PAGE_SIZE, CSAP_UC_PROT_ALL) != 0) {
        fprintf(stderr, "csap: map return address failed\n");
        goto fail;
    }
    if (csap_uc_mem_map(m->engine, CSAP_SCRATCH_BASE, CSAP_SCRATCH_SIZE, CSAP_UC_PROT_ALL) != 0) {
        fprintf(stderr, "csap: map scratch failed\n");
        goto fail;
    }
    if (csap_uc_mem_map(m->engine, CSAP_HEAP_BASE, CSAP_HEAP_SIZE, CSAP_UC_PROT_ALL) != 0) {
        fprintf(stderr, "csap: map heap failed\n");
        goto fail;
    }
    if (csap_uc_mem_map(m->engine, CSAP_STACK_BASE, CSAP_STACK_SIZE, CSAP_UC_PROT_ALL) != 0) {
        fprintf(stderr, "csap: map stack failed\n");
        goto fail;
    }

    // 写入 hlt 指令到 return address
    {
        uint8_t hlt = 0xF4;
        csap_uc_mem_write(m->engine, CSAP_RETURN_ADDRESS, &hlt, 1);
    }

    // 创建 shims（会映射 shim 区域）
    m->services = csap_shims_create(m->engine, m->corefp, icxs_data, icxs_size);
    if (m->services == NULL) {
        fprintf(stderr, "csap: create shims failed\n");
        goto fail;
    }

    // 注册额外的 zero-return shims
    if (extra_shims != NULL && extra_shims->names != NULL) {
        for (int i = 0; i < extra_shims->count; i++) {
            csap_shims_add_function(m->services, extra_shims->names[i], return_zero_handler, NULL);
        }
    }

    // 重定位并加载镜像
    if (csap_macho_relocate(m->corefp, CSAP_COREFP_BASE, resolver_resolve, &resolver) != 0) {
        fprintf(stderr, "csap: relocate CoreFP failed\n");
        goto fail;
    }
    if (csap_macho_load(m->corefp, mem_map_cb, mem_write_cb, m->engine) != 0) {
        fprintf(stderr, "csap: load CoreFP failed\n");
        goto fail;
    }

    if (csap_macho_relocate(m->commerce_core, CSAP_COMMERCE_BASE, resolver_resolve, &resolver) != 0) {
        fprintf(stderr, "csap: relocate CommerceCore failed\n");
        goto fail;
    }
    if (csap_macho_load(m->commerce_core, mem_map_cb, mem_write_cb, m->engine) != 0) {
        fprintf(stderr, "csap: load CommerceCore failed\n");
        goto fail;
    }

    if (csap_macho_relocate(m->commerce_kit, CSAP_KIT_BASE, resolver_resolve, &resolver) != 0) {
        fprintf(stderr, "csap: relocate CommerceKit failed\n");
        goto fail;
    }
    if (csap_macho_load(m->commerce_kit, mem_map_cb, mem_write_cb, m->engine) != 0) {
        fprintf(stderr, "csap: load CommerceKit failed\n");
        goto fail;
    }

    // 重定位并加载额外镜像
    for (int i = 0; i < extra_image_count; i++) {
        if (csap_macho_relocate(extra[i], extra_images[i].base, resolver_resolve, &resolver) != 0) {
            fprintf(stderr, "csap: relocate %s failed\n", extra_images[i].name);
            goto fail;
        }
        if (csap_macho_load(extra[i], mem_map_cb, mem_write_cb, m->engine) != 0) {
            fprintf(stderr, "csap: load %s failed\n", extra_images[i].name);
            goto fail;
        }
    }

    // 清理 resolver
    for (int i = 0; i < resolver.count; i++) free((void*)resolver.names[i]);
    free(resolver.names);
    free(resolver.addresses);

    return m;

fail:
    for (int i = 0; i < resolver.count; i++) free((void*)resolver.names[i]);
    free(resolver.names);
    free(resolver.addresses);
    csap_machine_close(m);
    return NULL;
}

// ==================== Initialize ====================

int csap_machine_initialize(csap_machine_t* m,
                            const uint8_t* hardware_id, size_t hardware_id_len,
                            uint64_t* out_context) {
    if (m == NULL || out_context == NULL) return -1;

    uint8_t hardware[24];
    if (make_hardware_block(hardware_id, hardware_id_len, hardware) != 0) {
        fprintf(stderr, "csap: invalid hardware ID\n");
        return -1;
    }

    m->scratch_cursor = 0;

    uint64_t context_field = csap_machine_scratch(m, NULL, 8);
    if (context_field == 0) goto fail;

    uint64_t hardware_addr = csap_machine_scratch(m, hardware, 24);
    if (hardware_addr == 0) goto fail;

    uint64_t args[2] = {context_field, hardware_addr};
    uint64_t status;
    if (csap_machine_invoke(m, m->entry.initialize, args, 2, &status) != 0) goto fail;

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: initialize returned %d\n", (int32_t)status);
        goto fail;
    }

    uint64_t context = csap_machine_read_u64(m, context_field);
    if (context == 0) {
        fprintf(stderr, "csap: initialize returned null context\n");
        goto fail;
    }

    csap_machine_clear_scratch(m);
    *out_context = context;
    return 0;

fail:
    csap_machine_clear_scratch(m);
    return -1;
}

// ==================== Exchange ====================

int csap_machine_exchange(csap_machine_t* m,
                          uint32_t version,
                          const uint8_t* hardware_id, size_t hardware_id_len,
                          uint64_t context,
                          const uint8_t* input, size_t input_len,
                          uint8_t** out_output, size_t* out_output_len,
                          int32_t* out_result) {
    if (m == NULL || input == NULL) return -1;

    uint8_t hardware[24];
    if (make_hardware_block(hardware_id, hardware_id_len, hardware) != 0) return -1;

    m->scratch_cursor = 0;

    uint64_t hardware_addr = csap_machine_scratch(m, hardware, 24);
    if (hardware_addr == 0) goto fail;

    uint64_t input_addr = csap_machine_scratch(m, input, input_len);
    if (input_addr == 0) goto fail;

    uint64_t output_field = csap_machine_scratch(m, NULL, 8);
    if (output_field == 0) goto fail;

    uint64_t length_field = csap_machine_scratch(m, NULL, 8);
    if (length_field == 0) goto fail;

    uint64_t result_field = csap_machine_scratch(m, NULL, 4);
    if (result_field == 0) goto fail;

    uint64_t args[8] = {
        (uint64_t)version,
        hardware_addr,
        context,
        input_addr,
        (uint64_t)input_len,
        output_field,
        length_field,
        result_field,
    };

    uint64_t status;
    if (csap_machine_invoke(m, m->entry.exchange, args, 8, &status) != 0) goto fail;

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: exchange returned %d\n", (int32_t)status);
        goto fail;
    }

    uint64_t pointer = csap_machine_read_u64(m, output_field);
    uint64_t length = csap_machine_read_u64(m, length_field);
    int32_t result = (int32_t)csap_machine_read_u32(m, result_field);

    uint8_t* output = NULL;
    if (length > CSAP_MAX_OUTPUT_SIZE) {
        fprintf(stderr, "csap: output too large (%llu)\n", (unsigned long long)length);
        goto fail;
    }
    if (length > 0 && pointer != 0) {
        output = malloc(length);
        if (output == NULL) goto fail;
        if (csap_uc_mem_read(m->engine, pointer, output, length) != 0) {
            free(output);
            goto fail;
        }
    }

    // dispose 输出
    if (pointer != 0) {
        uint64_t disp_args[1] = {pointer};
        uint64_t disp_status;
        csap_machine_invoke(m, m->entry.dispose, disp_args, 1, &disp_status);
    }

    if (out_output) *out_output = output;
    else free(output);
    if (out_output_len) *out_output_len = length;
    if (out_result) *out_result = result;

    csap_machine_clear_scratch(m);
    return 0;

fail:
    csap_machine_clear_scratch(m);
    return -1;
}

// ==================== Sign ====================

int csap_machine_sign(csap_machine_t* m,
                      uint64_t context,
                      const uint8_t* input, size_t input_len,
                      uint8_t** out_output, size_t* out_output_len) {
    if (m == NULL || input == NULL) return -1;

    m->scratch_cursor = 0;

    uint64_t input_addr = csap_machine_scratch(m, input, input_len);
    if (input_addr == 0) goto fail;

    uint64_t output_field = csap_machine_scratch(m, NULL, 8);
    if (output_field == 0) goto fail;

    uint64_t length_field = csap_machine_scratch(m, NULL, 8);
    if (length_field == 0) goto fail;

    uint64_t args[5] = {
        context,
        input_addr,
        (uint64_t)input_len,
        output_field,
        length_field,
    };

    uint64_t status;
    if (csap_machine_invoke(m, m->entry.sign, args, 5, &status) != 0) goto fail;

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: sign returned %d\n", (int32_t)status);
        goto fail;
    }

    uint64_t pointer = csap_machine_read_u64(m, output_field);
    uint64_t length = csap_machine_read_u64(m, length_field);

    uint8_t* output = NULL;
    if (length > CSAP_MAX_OUTPUT_SIZE) {
        fprintf(stderr, "csap: sign output too large (%llu)\n", (unsigned long long)length);
        goto fail;
    }
    if (length > 0 && pointer != 0) {
        output = malloc(length);
        if (output == NULL) goto fail;
        if (csap_uc_mem_read(m->engine, pointer, output, length) != 0) {
            free(output);
            goto fail;
        }
    }

    if (pointer != 0) {
        uint64_t disp_args[1] = {pointer};
        uint64_t disp_status;
        csap_machine_invoke(m, m->entry.dispose, disp_args, 1, &disp_status);
    }

    if (out_output) *out_output = output;
    else free(output);
    if (out_output_len) *out_output_len = length;

    csap_machine_clear_scratch(m);
    return 0;

fail:
    csap_machine_clear_scratch(m);
    return -1;
}

// ==================== Close ====================

void csap_machine_close(csap_machine_t* m) {
    if (m == NULL || m->closed) return;
    m->closed = 1;

    if (m->services) {
        csap_shims_close(m->services);
        m->services = NULL;
    }
    if (m->engine) {
        csap_uc_close(m->engine);
        m->engine = NULL;
    }
    if (m->corefp) { csap_macho_free(m->corefp); m->corefp = NULL; }
    if (m->commerce_core) { csap_macho_free(m->commerce_core); m->commerce_core = NULL; }
    if (m->commerce_kit) { csap_macho_free(m->commerce_kit); m->commerce_kit = NULL; }
    if (m->extra_images) {
        for (int i = 0; i < m->extra_image_count; i++) {
            if (m->extra_images[i]) csap_macho_free(m->extra_images[i]);
        }
        free(m->extra_images);
        m->extra_images = NULL;
    }

    free(m);
}

csap_machine_t* csap_machine_open(const uint8_t* corefp_data, size_t corefp_size,
                                  const uint8_t* commercecore_data, size_t commercecore_size,
                                  const uint8_t* commercekit_data, size_t commercekit_size,
                                  const uint8_t* icxs_data, size_t icxs_size) {
    return csap_machine_open_extended(corefp_data, corefp_size,
                                      commercecore_data, commercecore_size,
                                      commercekit_data, commercekit_size,
                                      icxs_data, icxs_size,
                                      NULL, 0, NULL);
}
