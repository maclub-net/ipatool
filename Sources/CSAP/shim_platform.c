#include "shims.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>

#define CSAP_FAKE_HANDLE   UINT64_MAX
#define CSAP_COREFP_FILE   3
#define CSAP_COREFP_PATH   "/System/Library/PrivateFrameworks/CoreFP.framework/CoreFP"
#define CSAP_ICXS_PATH     "./../CoreFP.icxs"
#define CSAP_KEY_SERIAL    "IOPlatformSerialNumber"
#define CSAP_KEY_UUID      "IOPlatformUUID"
#define CSAP_KEY_BOARD     "board-id"
#define CSAP_KEYED_MESSAGE "objectForKey:"

// ==================== 简单返回值 ====================

static int shim_return_zero(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, 0);
}

static int shim_return_fake_handle(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, CSAP_FAKE_HANDLE);
}

static int shim_return_uint32_max(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, UINT32_MAX);
}

static int shim_return_minus_one(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, UINT64_MAX);
}

// ==================== CoreFoundation ====================

static int shim_cf_string_create(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t cstr_addr;
    if (csap_shims_arg(s, 1, &cstr_addr) != 0) return -1;

    char value[256];
    if (csap_shims_read_cstring(s, cstr_addr, value, sizeof(value)) != 0) return -1;

    if (strcmp(value, CSAP_KEY_SERIAL) == 0 ||
        strcmp(value, CSAP_KEY_UUID) == 0 ||
        strcmp(value, CSAP_KEY_BOARD) == 0) {
        return csap_shims_set_result(s, CSAP_FAKE_HANDLE);
    }
    return csap_shims_set_result(s, 0);
}

static int shim_cf_string_get_cstring(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t buffer, capacity;
    if (csap_shims_arg(s, 1, &buffer) != 0) return -1;
    if (csap_shims_arg(s, 2, &capacity) != 0) return -1;

    if (buffer == 0 || capacity == 0) {
        return csap_shims_set_result(s, 0);
    }

    uint8_t zero = 0;
    csap_uc_mem_write(csap_shims_engine(s), buffer, &zero, 1);
    return csap_shims_set_result(s, 1);
}

// ==================== IOKit ====================

static int shim_io_iterator_next(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint32_t iter = csap_shims_iterator(s) + 1;
    csap_shims_set_iterator(s, iter);
    return csap_shims_set_result(s, (uint64_t)(iter % 2));
}

static int shim_io_registry_entry_get_parent(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t parent;
    if (csap_shims_arg(s, 2, &parent) != 0) return -1;
    if (parent == 0) return -1;

    csap_shims_write_u32(s, parent, UINT32_MAX);
    return csap_shims_set_result(s, 0);
}

static int shim_io_service_get_matching_services(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t iterator;
    if (csap_shims_arg(s, 2, &iterator) != 0) return -1;
    if (iterator == 0) return -1;

    csap_shims_set_iterator(s, 0);
    csap_shims_write_u32(s, iterator, UINT32_MAX);
    return csap_shims_set_result(s, 0);
}

// ==================== 原子操作 ====================

static int shim_compare_and_swap32(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t old_val, new_val, address;
    if (csap_shims_arg(s, 0, &old_val) != 0) return -1;
    if (csap_shims_arg(s, 1, &new_val) != 0) return -1;
    if (csap_shims_arg(s, 2, &address) != 0) return -1;

    uint32_t current;
    if (csap_shims_read_u32(s, address, &current) != 0) return -1;

    if (current != (uint32_t)old_val) {
        return csap_shims_set_result(s, 0);
    }
    csap_shims_write_u32(s, address, (uint32_t)new_val);
    return csap_shims_set_result(s, 1);
}

// ==================== 系统 ====================

static int shim_error_pointer(csap_shims_t* s, void* ctx) {
    (void)ctx;
    return csap_shims_set_result(s, csap_shims_errno_addr(s));
}

static int shim_abort(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t rip = 0;
    csap_uc_reg_read(csap_shims_engine(s), CSAP_REG_RIP, &rip);
    fprintf(stderr, "csap: guest aborted at RIP=0x%llx\n", (unsigned long long)rip);
    return -1;
}

static int shim_arc4random(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint32_t value = 0;
    arc4random_buf(&value, sizeof(value));
    return csap_shims_set_result(s, (uint64_t)value);
}

static int shim_dlopen(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t path_addr;
    if (csap_shims_arg(s, 0, &path_addr) != 0) return -1;

    char path[512];
    if (csap_shims_read_cstring(s, path_addr, path, sizeof(path)) != 0) return -1;

    if (strcmp(path, CSAP_COREFP_PATH) == 0) {
        return csap_shims_set_result(s, CSAP_FAKE_HANDLE);
    }
    return csap_shims_set_result(s, 0);
}

static int shim_dlsym(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t name_addr;
    if (csap_shims_arg(s, 1, &name_addr) != 0) return -1;

    char name[256];
    if (csap_shims_read_cstring(s, name_addr, name, sizeof(name)) != 0) return -1;

    // 查找 CoreFP 导出符号
    char full_name[260];
    snprintf(full_name, sizeof(full_name), "_%s", name);

    uint64_t address = 0;
    csap_macho_image_t* corefp = csap_shims_corefp(s);
    if (corefp != NULL) {
        // 使用 CoreFP 的基址 0x100000000000
        csap_macho_export(corefp, full_name, 0x100000000000ULL, &address);
    }
    return csap_shims_set_result(s, address);
}

static int shim_gettimeofday(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t time_addr, zone_addr;
    if (csap_shims_arg(s, 0, &time_addr) != 0) return -1;
    if (csap_shims_arg(s, 1, &zone_addr) != 0) return -1;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    if (time_addr != 0) {
        uint8_t buf[16] = {0};
        uint64_t sec = (uint64_t)ts.tv_sec;
        uint32_t usec = (uint32_t)(ts.tv_nsec / 1000);
        for (int i = 0; i < 8; i++) buf[i] = (uint8_t)(sec >> (i * 8));
        for (int i = 0; i < 4; i++) buf[8 + i] = (uint8_t)(usec >> (i * 8));
        csap_uc_mem_write(csap_shims_engine(s), time_addr, buf, 16);
    }
    if (zone_addr != 0) {
        uint8_t zero[8] = {0};
        csap_uc_mem_write(csap_shims_engine(s), zone_addr, zero, 8);
    }
    return csap_shims_set_result(s, 0);
}

static int shim_objc_msg_send(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t sel_addr;
    if (csap_shims_arg(s, 1, &sel_addr) != 0) return -1;

    char selector[256];
    if (csap_shims_read_cstring(s, sel_addr, selector, sizeof(selector)) != 0) return -1;

    if (strcmp(selector, CSAP_KEYED_MESSAGE) == 0) {
        return csap_shims_set_result(s, CSAP_FAKE_HANDLE);
    }
    return csap_shims_set_result(s, 0);
}

static int shim_open(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t path_addr;
    if (csap_shims_arg(s, 0, &path_addr) != 0) return -1;

    char path[512];
    if (csap_shims_read_cstring(s, path_addr, path, sizeof(path)) != 0) return -1;

    if (strcmp(path, CSAP_ICXS_PATH) == 0) {
        csap_shims_set_icxs_offset(s, 0);
        return csap_shims_set_result(s, CSAP_COREFP_FILE);
    }
    return shim_return_minus_one(s, ctx);
}

static int shim_pthread_once(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t control, initializer;
    if (csap_shims_arg(s, 0, &control) != 0) return -1;
    if (csap_shims_arg(s, 1, &initializer) != 0) return -1;

    uint64_t value;
    if (csap_shims_read_u64(s, control, &value) != 0) return -1;

    if (value == 0) {
        return csap_shims_set_result(s, 0);
    }

    csap_shims_write_u64(s, control, 0);

    // 将 initializer 压入栈，让 ret 跳转到它
    uint64_t rsp;
    csap_uc_reg_read(csap_shims_engine(s), CSAP_REG_RSP, &rsp);
    rsp -= 8;
    csap_shims_write_u64(s, rsp, initializer);
    csap_uc_reg_write(csap_shims_engine(s), CSAP_REG_RSP, rsp);

    return csap_shims_set_result(s, 0);
}

static int shim_read(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t fd, buffer, requested;
    if (csap_shims_arg(s, 0, &fd) != 0) return -1;
    if (csap_shims_arg(s, 1, &buffer) != 0) return -1;
    if (csap_shims_arg(s, 2, &requested) != 0) return -1;

    if (fd != CSAP_COREFP_FILE) {
        return shim_return_minus_one(s, ctx);
    }

    uint64_t icxs_size = csap_shims_icxs_size(s);
    uint64_t offset = csap_shims_icxs_offset(s);
    uint64_t remaining = icxs_size - offset;
    uint64_t size = requested < remaining ? requested : remaining;

    if (size > 0) {
        const uint8_t* icxs = csap_shims_icxs(s);
        csap_uc_mem_write(csap_shims_engine(s), buffer, icxs + offset, size);
        csap_shims_set_icxs_offset(s, offset + size);
    }
    return csap_shims_set_result(s, size);
}

static int shim_sysctlbyname(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t length_addr;
    if (csap_shims_arg(s, 2, &length_addr) != 0) return -1;
    if (length_addr != 0) {
        csap_shims_write_u64(s, length_addr, 0);
    }
    return csap_shims_set_result(s, 0);
}

// ==================== 注册 ====================

static void add_alias(csap_shims_t* s, const char** names, int count, csap_shim_handler_t handler) {
    for (int i = 0; i < count; i++) {
        csap_shims_add_function(s, names[i], handler, NULL);
    }
}

int csap_shims_register_platform_services(csap_shims_t* s) {
    if (s == NULL) return -1;

    // 返回 0 的服务
    const char* zero1[] = {"_CFBundleGetMainBundle", "_CFDataGetBytePtr", "_CFDataGetLength",
                           "_CFStringGetLength", "_CFStringGetMaximumSizeForEncoding",
                           "_CFUUIDCreateString", "_IORegistryEntryFromPath",
                           "_IORegistryEntrySearchCFProperty", "_IOServiceMatching",
                           "_getenv", "_pthread_self"};
    add_alias(s, zero1, 11, shim_return_zero);

    const char* zero2[] = {"_CFRelease", "_IOObjectRelease", "_close", "_close$UNIX2003",
                           "_pthread_mutex_lock", "_pthread_mutex_unlock",
                           "_pthread_rwlock_init", "_pthread_rwlock_init$UNIX2003",
                           "_pthread_rwlock_unlock", "_pthread_rwlock_unlock$UNIX2003",
                           "_pthread_rwlock_wrlock", "_pthread_rwlock_wrlock$UNIX2003"};
    add_alias(s, zero2, 12, shim_return_zero);

    const char* zero3[] = {"_CFStringCreateWithCStringNoCopy"};
    add_alias(s, zero3, 1, shim_return_zero);

    // 返回 fake handle 的服务
    const char* fake[] = {"_CFDictionaryGetValue", "_DADiskCopyDescription",
                          "_DADiskCreateFromBSDName", "_DASessionCreate",
                          "_IORegistryEntryCreateCFProperty"};
    add_alias(s, fake, 5, shim_return_fake_handle);

    // 返回 -1 的服务
    const char* minus1[] = {"_fcntl", "_fcntl$UNIX2003", "_lstat$INODE64",
                            "_statfs", "_statfs$INODE64", "_sysctl"};
    add_alias(s, minus1, 6, shim_return_minus_one);

    // 具体实现的服务
    add_alias(s, (const char*[]){"_CFStringCreateWithCString"}, 1, shim_cf_string_create);
    add_alias(s, (const char*[]){"_CFStringGetCString"}, 1, shim_cf_string_get_cstring);
    add_alias(s, (const char*[]){"_IOIteratorNext"}, 1, shim_io_iterator_next);
    add_alias(s, (const char*[]){"_IORegistryEntryGetParentEntry"}, 1, shim_io_registry_entry_get_parent);
    add_alias(s, (const char*[]){"_IOServiceGetMatchingServices"}, 1, shim_io_service_get_matching_services);
    add_alias(s, (const char*[]){"_IOServiceGetMatchingService"}, 1, shim_return_uint32_max);
    add_alias(s, (const char*[]){"_OSAtomicCompareAndSwap32Barrier"}, 1, shim_compare_and_swap32);
    add_alias(s, (const char*[]){"___error"}, 1, shim_error_pointer);
    add_alias(s, (const char*[]){"_abort", "___stack_chk_fail", "dyld_stub_binder"}, 3, shim_abort);
    add_alias(s, (const char*[]){"_arc4random"}, 1, shim_arc4random);
    add_alias(s, (const char*[]){"_dlopen"}, 1, shim_dlopen);
    add_alias(s, (const char*[]){"_dlsym"}, 1, shim_dlsym);
    add_alias(s, (const char*[]){"_gettimeofday"}, 1, shim_gettimeofday);
    add_alias(s, (const char*[]){"_objc_msgSend"}, 1, shim_objc_msg_send);
    add_alias(s, (const char*[]){"_open", "_open$UNIX2003"}, 2, shim_open);
    add_alias(s, (const char*[]){"_pthread_once"}, 1, shim_pthread_once);
    add_alias(s, (const char*[]){"_read", "_read$UNIX2003"}, 2, shim_read);
    add_alias(s, (const char*[]){"_sysctlbyname"}, 1, shim_sysctlbyname);

    // 数据区域
    uint8_t zero8[8] = {0};
    uint64_t errno_addr = csap_shims_add_data(s, "guest.errno", zero8, 8);
    csap_shims_set_errno_addr(s, errno_addr);

    uint8_t stack_chk_guard[8] = {0xA5, 0x71, 0x3C, 0xD9, 0x86, 0x42, 0xEF, 0x10};
    csap_shims_add_data(s, "___stack_chk_guard", stack_chk_guard, 8);

    const char* data_names[] = {
        "_kCFAllocatorDefault", "_kCFAllocatorNull",
        "_kDADiskDescriptionVolumeUUIDKey", "_kIOMasterPortDefault"
    };
    for (int i = 0; i < 4; i++) {
        csap_shims_add_data(s, data_names[i], zero8, 8);
    }

    return 0;
}
