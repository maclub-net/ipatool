#include "unicorn.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// libunicorn 函数指针类型
typedef uint32_t    (*fn_uc_version)(uint32_t* major, uint32_t* minor);
typedef int32_t     (*fn_uc_open)(int32_t arch, int32_t mode, void** handle);
typedef int32_t     (*fn_uc_close)(void* handle);
typedef int32_t     (*fn_uc_query)(void* handle, int32_t type, uint64_t* result);
typedef const char* (*fn_uc_strerror)(int32_t code);
typedef int32_t     (*fn_uc_mem_map)(void* handle, uint64_t address, uint64_t size, uint32_t perms);
typedef int32_t     (*fn_uc_mem_unmap)(void* handle, uint64_t address, uint64_t size);
typedef int32_t     (*fn_uc_mem_read)(void* handle, uint64_t address, void* buffer, uint64_t size);
typedef int32_t     (*fn_uc_mem_write)(void* handle, uint64_t address, const void* buffer, uint64_t size);
typedef int32_t     (*fn_uc_reg_read)(void* handle, int32_t regid, void* value);
typedef int32_t     (*fn_uc_reg_write)(void* handle, int32_t regid, const void* value);
typedef int32_t     (*fn_uc_emu_start)(void* handle, uint64_t begin, uint64_t end, uint64_t timeout, uint64_t count);
typedef int32_t     (*fn_uc_emu_stop)(void* handle);
typedef int32_t     (*fn_uc_hook_add)(void* handle, void** hook, int32_t type,
                                      void* callback, void* user_data,
                                      uint64_t begin, uint64_t end);
typedef int32_t     (*fn_uc_hook_del)(void* handle, void* hook);

// 全局函数指针表
static struct {
    void* handle;
    fn_uc_version    version;
    fn_uc_open       open;
    fn_uc_close      close;
    fn_uc_query      query;
    fn_uc_strerror   strerror;
    fn_uc_mem_map    mem_map;
    fn_uc_mem_unmap  mem_unmap;
    fn_uc_mem_read   mem_read;
    fn_uc_mem_write  mem_write;
    fn_uc_reg_read   reg_read;
    fn_uc_reg_write  reg_write;
    fn_uc_emu_start  emu_start;
    fn_uc_emu_stop   emu_stop;
    fn_uc_hook_add   hook_add;
    fn_uc_hook_del   hook_del;
} g_uc_api = {0};

// 引擎结构体
struct csap_uc_engine {
    void* handle;
};

int csap_uc_load(const char* dylib_path) {
    if (g_uc_api.handle != NULL) {
        return 0;  // 已加载
    }

    g_uc_api.handle = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (g_uc_api.handle == NULL) {
        fprintf(stderr, "csap: failed to load unicorn: %s\n", dlerror());
        return -1;
    }

    #define RESOLVE(field, sym) \
        g_uc_api.field = (fn_uc_##field)dlsym(g_uc_api.handle, sym); \
        if (g_uc_api.field == NULL) { \
            fprintf(stderr, "csap: failed to resolve %s: %s\n", sym, dlerror()); \
            dlclose(g_uc_api.handle); \
            memset(&g_uc_api, 0, sizeof(g_uc_api)); \
            return -1; \
        }

    RESOLVE(version,    "uc_version")
    RESOLVE(open,       "uc_open")
    RESOLVE(close,      "uc_close")
    RESOLVE(query,      "uc_query")
    RESOLVE(strerror,   "uc_strerror")
    RESOLVE(mem_map,    "uc_mem_map")
    RESOLVE(mem_unmap,  "uc_mem_unmap")
    RESOLVE(mem_read,   "uc_mem_read")
    RESOLVE(mem_write,  "uc_mem_write")
    RESOLVE(reg_read,   "uc_reg_read")
    RESOLVE(reg_write,  "uc_reg_write")
    RESOLVE(emu_start,  "uc_emu_start")
    RESOLVE(emu_stop,   "uc_emu_stop")
    RESOLVE(hook_add,   "uc_hook_add")
    RESOLVE(hook_del,   "uc_hook_del")

    #undef RESOLVE

    // 验证版本
    uint32_t major = 0, minor = 0;
    g_uc_api.version(&major, &minor);
    if (major != 2 || minor != 1) {
        fprintf(stderr, "csap: unsupported unicorn version %u.%u (expected 2.1)\n", major, minor);
        dlclose(g_uc_api.handle);
        memset(&g_uc_api, 0, sizeof(g_uc_api));
        return -1;
    }

    return 0;
}

void csap_uc_unload(void) {
    if (g_uc_api.handle != NULL) {
        dlclose(g_uc_api.handle);
        memset(&g_uc_api, 0, sizeof(g_uc_api));
    }
}

csap_uc_engine_t* csap_uc_open(int32_t arch, int32_t mode) {
    if (g_uc_api.handle == NULL) {
        return NULL;
    }

    void* handle = NULL;
    if (g_uc_api.open(arch, mode, &handle) != 0) {
        return NULL;
    }

    csap_uc_engine_t* uc = malloc(sizeof(csap_uc_engine_t));
    if (uc == NULL) {
        g_uc_api.close(handle);
        return NULL;
    }
    uc->handle = handle;
    return uc;
}

int csap_uc_close(csap_uc_engine_t* uc) {
    if (uc == NULL) return -1;
    int ret = g_uc_api.close(uc->handle);
    free(uc);
    return ret;
}

int csap_uc_mem_map(csap_uc_engine_t* uc, uint64_t address, uint64_t size, uint32_t perms) {
    return g_uc_api.mem_map(uc->handle, address, size, perms);
}

int csap_uc_mem_unmap(csap_uc_engine_t* uc, uint64_t address, uint64_t size) {
    return g_uc_api.mem_unmap(uc->handle, address, size);
}

int csap_uc_mem_read(csap_uc_engine_t* uc, uint64_t address, void* buffer, uint64_t size) {
    return g_uc_api.mem_read(uc->handle, address, buffer, size);
}

int csap_uc_mem_write(csap_uc_engine_t* uc, uint64_t address, const void* buffer, uint64_t size) {
    return g_uc_api.mem_write(uc->handle, address, buffer, size);
}

int csap_uc_reg_read(csap_uc_engine_t* uc, int32_t regid, uint64_t* value) {
    return g_uc_api.reg_read(uc->handle, regid, value);
}

int csap_uc_reg_write(csap_uc_engine_t* uc, int32_t regid, uint64_t value) {
    return g_uc_api.reg_write(uc->handle, regid, &value);
}

int csap_uc_emu_start(csap_uc_engine_t* uc, uint64_t begin, uint64_t end, uint64_t timeout, uint64_t count) {
    return g_uc_api.emu_start(uc->handle, begin, end, timeout, count);
}

int csap_uc_emu_stop(csap_uc_engine_t* uc) {
    return g_uc_api.emu_stop(uc->handle);
}

int csap_uc_hook_add(csap_uc_engine_t* uc, csap_uc_hook_t* hook, int32_t type,
                     csap_uc_hook_cb callback, void* user_data,
                     uint64_t begin, uint64_t end) {
    void* hook_handle = NULL;
    int ret = g_uc_api.hook_add(uc->handle, &hook_handle, type,
                                (void*)callback, user_data, begin, end);
    if (ret == 0 && hook != NULL) {
        *hook = (csap_uc_hook_t)hook_handle;
    }
    return ret;
}

int csap_uc_hook_del(csap_uc_engine_t* uc, csap_uc_hook_t hook) {
    return g_uc_api.hook_del(uc->handle, (void*)hook);
}

int csap_uc_query(csap_uc_engine_t* uc, int32_t query_type, uint64_t* result) {
    return g_uc_api.query(uc->handle, query_type, result);
}

const char* csap_uc_strerror(int32_t code) {
    if (g_uc_api.handle == NULL) return "unicorn not loaded";
    return g_uc_api.strerror(code);
}
