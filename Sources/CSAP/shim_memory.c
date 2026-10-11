#include "shims.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ==================== 辅助 ====================

static int checked_size(uint64_t value, size_t* out) {
    if (value > CSAP_MAX_GUEST_TRANSFER) return -1;
    *out = (size_t)value;
    return 0;
}

// ==================== malloc 系列 ====================

static int shim_malloc(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t size;
    if (csap_shims_arg(s, 0, &size) != 0) return -1;

    uint64_t addr = csap_shims_allocate(s, size);
    if (addr == 0) return -1;

    return csap_shims_set_result(s, addr);
}

static int shim_malloc_good_size(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t size;
    if (csap_shims_arg(s, 0, &size) != 0) return -1;
    if (size < 1) size = 1;
    return csap_shims_set_result(s, (size + 15) & ~15ULL);
}

static int shim_malloc_size(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t addr;
    if (csap_shims_arg(s, 0, &addr) != 0) return -1;

    uint64_t sz = csap_shims_allocation_size(s, addr);
    return csap_shims_set_result(s, sz);
}

static int shim_calloc(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t count, size;
    if (csap_shims_arg(s, 0, &count) != 0) return -1;
    if (csap_shims_arg(s, 1, &size) != 0) return -1;

    if (count != 0 && size > UINT64_MAX / count) return -1;
    uint64_t total = count * size;

    uint64_t addr = csap_shims_allocate(s, total);
    if (addr == 0) return -1;

    if (total > 0) {
        // 清零
        uint8_t* zeroes = calloc(1, (size_t)total);
        if (zeroes == NULL) {
            csap_shims_release(s, addr);
            return -1;
        }
        csap_uc_mem_write(csap_shims_engine(s), addr, zeroes, total);
        free(zeroes);
    }

    return csap_shims_set_result(s, addr);
}

static int shim_realloc(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t old_addr, new_size;
    if (csap_shims_arg(s, 0, &old_addr) != 0) return -1;
    if (csap_shims_arg(s, 1, &new_size) != 0) return -1;

    if (old_addr == 0) {
        uint64_t addr = csap_shims_allocate(s, new_size);
        return csap_shims_set_result(s, addr);
    }

    uint64_t old_reserved = csap_shims_allocation_size(s, old_addr);
    if (old_reserved == 0) return -1;  // 未知指针

    if (new_size <= old_reserved) {
        return csap_shims_set_result(s, old_addr);
    }

    uint64_t new_addr = csap_shims_allocate(s, new_size);
    if (new_addr == 0) return -1;

    // 复制旧数据
    uint8_t* buf = malloc((size_t)old_reserved);
    if (buf == NULL) {
        csap_shims_release(s, new_addr);
        return -1;
    }
    csap_uc_engine_t* eng = csap_shims_engine(s);
    csap_uc_mem_read(eng, old_addr, buf, old_reserved);
    csap_uc_mem_write(eng, new_addr, buf, old_reserved);
    free(buf);

    csap_shims_release(s, old_addr);
    return csap_shims_set_result(s, new_addr);
}

static int shim_free(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t addr;
    if (csap_shims_arg(s, 0, &addr) != 0) return -1;

    if (addr != 0) {
        csap_shims_release(s, addr);
    }
    return csap_shims_set_result(s, 0);
}

// ==================== 内存操作 ====================

static int shim_memmove(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t dst, src, len;
    if (csap_shims_arg(s, 0, &dst) != 0) return -1;
    if (csap_shims_arg(s, 1, &src) != 0) return -1;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;

    size_t size;
    if (checked_size(len, &size) != 0) return -1;

    uint8_t* buf = malloc(size);
    if (buf == NULL) return -1;

    csap_uc_engine_t* eng = csap_shims_engine(s);
    csap_uc_mem_read(eng, src, buf, len);
    csap_uc_mem_write(eng, dst, buf, len);
    free(buf);

    return csap_shims_set_result(s, dst);
}

static int shim_memset(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t dst, value, len;
    if (csap_shims_arg(s, 0, &dst) != 0) return -1;
    if (csap_shims_arg(s, 1, &value) != 0) return -1;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;

    size_t size;
    if (checked_size(len, &size) != 0) return -1;

    uint8_t* buf = malloc(size);
    if (buf == NULL) return -1;
    memset(buf, (int)value, size);

    csap_uc_mem_write(csap_shims_engine(s), dst, buf, len);
    free(buf);

    return csap_shims_set_result(s, dst);
}

static int shim_bzero(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t dst, len;
    if (csap_shims_arg(s, 0, &dst) != 0) return -1;
    if (csap_shims_arg(s, 1, &len) != 0) return -1;

    size_t size;
    if (checked_size(len, &size) != 0) return -1;

    uint8_t* buf = calloc(1, size);
    if (buf == NULL) return -1;
    csap_uc_mem_write(csap_shims_engine(s), dst, buf, len);
    free(buf);

    return csap_shims_set_result(s, dst);
}

static int shim_checked_memcpy(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t len, cap;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;
    if (csap_shims_arg(s, 3, &cap) != 0) return -1;
    if (len > cap) return -1;
    return shim_memmove(s, ctx);
}

static int shim_checked_memset(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t len, cap;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;
    if (csap_shims_arg(s, 3, &cap) != 0) return -1;
    if (len > cap) return -1;
    return shim_memset(s, ctx);
}

static int shim_memcmp(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t left, right, len;
    if (csap_shims_arg(s, 0, &left) != 0) return -1;
    if (csap_shims_arg(s, 1, &right) != 0) return -1;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;

    size_t size;
    if (checked_size(len, &size) != 0) return -1;

    uint8_t* a = malloc(size);
    uint8_t* b = malloc(size);
    if (a == NULL || b == NULL) { free(a); free(b); return -1; }

    csap_uc_engine_t* eng = csap_shims_engine(s);
    csap_uc_mem_read(eng, left, a, len);
    csap_uc_mem_read(eng, right, b, len);

    int result = memcmp(a, b, size);
    free(a);
    free(b);

    return csap_shims_set_result(s, (uint64_t)(int64_t)result);
}

static int shim_strcmp(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t left, right;
    if (csap_shims_arg(s, 0, &left) != 0) return -1;
    if (csap_shims_arg(s, 1, &right) != 0) return -1;

    char a[4096], b[4096];
    if (csap_shims_read_cstring(s, left, a, sizeof(a)) != 0) return -1;
    if (csap_shims_read_cstring(s, right, b, sizeof(b)) != 0) return -1;

    int result = strcmp(a, b);
    return csap_shims_set_result(s, (uint64_t)(int64_t)result);
}

static int shim_strncmp(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t left, right, len;
    if (csap_shims_arg(s, 0, &left) != 0) return -1;
    if (csap_shims_arg(s, 1, &right) != 0) return -1;
    if (csap_shims_arg(s, 2, &len) != 0) return -1;

    size_t size;
    if (checked_size(len, &size) != 0) return -1;

    uint8_t* a = malloc(size > 0 ? size : 1);
    uint8_t* b = malloc(size > 0 ? size : 1);
    if (a == NULL || b == NULL) { free(a); free(b); return -1; }

    csap_uc_engine_t* eng = csap_shims_engine(s);
    csap_uc_mem_read(eng, left, a, len);
    csap_uc_mem_read(eng, right, b, len);

    int result = 0;
    for (size_t i = 0; i < size; i++) {
        if (a[i] != b[i]) {
            result = (int)a[i] - (int)b[i];
            break;
        }
        if (a[i] == 0) break;
    }
    free(a);
    free(b);

    return csap_shims_set_result(s, (uint64_t)(int64_t)result);
}

static int shim_strlen(csap_shims_t* s, void* ctx) {
    (void)ctx;
    uint64_t addr;
    if (csap_shims_arg(s, 0, &addr) != 0) return -1;

    char buf[4096];
    if (csap_shims_read_cstring(s, addr, buf, sizeof(buf)) != 0) return -1;

    return csap_shims_set_result(s, (uint64_t)strlen(buf));
}

// ==================== 注册 ====================

static void add_alias(csap_shims_t* s, const char** names, int count, csap_shim_handler_t handler) {
    for (int i = 0; i < count; i++) {
        csap_shims_add_function(s, names[i], handler, NULL);
    }
}

int csap_shims_register_memory_services(csap_shims_t* s) {
    if (s == NULL) return -1;

    const char* malloc_names[] = {"_malloc"};
    const char* malloc_good_names[] = {"_malloc_good_size"};
    const char* malloc_size_names[] = {"_malloc_size"};
    const char* calloc_names[] = {"_calloc"};
    const char* realloc_names[] = {"_realloc", "_reallocf"};
    const char* free_names[] = {"_free"};
    const char* memmove_names[] = {"_memcpy", "_memmove"};
    const char* memset_names[] = {"_memset"};
    const char* bzero_names[] = {"___bzero"};
    const char* chk_memcpy_names[] = {"___memcpy_chk"};
    const char* chk_memset_names[] = {"___memset_chk"};
    const char* memcmp_names[] = {"_memcmp"};
    const char* strcmp_names[] = {"_strcmp"};
    const char* strncmp_names[] = {"_strncmp"};
    const char* strlen_names[] = {"_strlen"};

    add_alias(s, malloc_names, 1, shim_malloc);
    add_alias(s, malloc_good_names, 1, shim_malloc_good_size);
    add_alias(s, malloc_size_names, 1, shim_malloc_size);
    add_alias(s, calloc_names, 1, shim_calloc);
    add_alias(s, realloc_names, 2, shim_realloc);
    add_alias(s, free_names, 1, shim_free);
    add_alias(s, memmove_names, 2, shim_memmove);
    add_alias(s, memset_names, 1, shim_memset);
    add_alias(s, bzero_names, 1, shim_bzero);
    add_alias(s, chk_memcpy_names, 1, shim_checked_memcpy);
    add_alias(s, chk_memset_names, 1, shim_checked_memset);
    add_alias(s, memcmp_names, 1, shim_memcmp);
    add_alias(s, strcmp_names, 1, shim_strcmp);
    add_alias(s, strncmp_names, 1, shim_strncmp);
    add_alias(s, strlen_names, 1, shim_strlen);

    return 0;
}
