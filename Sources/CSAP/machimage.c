#include "machimage.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

// ==================== Mach-O 结构体定义 ====================

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
} csap_mh_header_64_t;

typedef struct {
    uint32_t magic;
    uint32_t nfat_arch;
} csap_fat_header_t;

typedef struct {
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t offset;
    uint32_t size;
    uint32_t align;
} csap_fat_arch_t;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
} csap_load_command_t;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
    char     segname[16];
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    uint32_t maxprot;
    uint32_t initprot;
    uint32_t nsects;
    uint32_t flags;
} csap_segment_command_64_t;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t rebase_off;
    uint32_t rebase_size;
    uint32_t bind_off;
    uint32_t bind_size;
    uint32_t weak_bind_off;
    uint32_t weak_bind_size;
    uint32_t lazy_bind_off;
    uint32_t lazy_bind_size;
    uint32_t export_off;
    uint32_t export_size;
} csap_dyld_info_command_t;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t symoff;
    uint32_t nsyms;
    uint32_t stroff;
    uint32_t strsize;
} csap_symtab_command_t;

struct nlist_64 {
    uint32_t n_strx;
    uint8_t  n_type;
    uint8_t  n_sect;
    uint16_t n_desc;
    uint64_t n_value;
};

#pragma pack(pop)

// ==================== 辅助函数 ====================

static inline uint32_t read_u32_be(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | ((uint32_t)p[3]);
}

static inline uint32_t read_u32_le(const uint8_t* p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[1] << 8)  | ((uint32_t)p[0]);
}

static inline uint64_t read_u64_le(const uint8_t* p) {
    return ((uint64_t)p[7] << 56) | ((uint64_t)p[6] << 48) |
           ((uint64_t)p[5] << 40) | ((uint64_t)p[4] << 32) |
           ((uint64_t)p[3] << 24) | ((uint64_t)p[2] << 16) |
           ((uint64_t)p[1] << 8)  | ((uint64_t)p[0]);
}

static inline void write_u64_le(uint8_t* p, uint64_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
    p[4] = (uint8_t)(v >> 32);
    p[5] = (uint8_t)(v >> 40);
    p[6] = (uint8_t)(v >> 48);
    p[7] = (uint8_t)(v >> 56);
}

// ULEB128 解码
static uint64_t read_uleb128(const uint8_t** pp, const uint8_t* end) {
    uint64_t result = 0;
    int shift = 0;
    while (*pp < end) {
        uint8_t byte = *(*pp)++;
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    return result;
}

// SLEB128 解码
static int64_t read_sleb128(const uint8_t** pp, const uint8_t* end) {
    int64_t result = 0;
    int shift = 0;
    uint8_t byte;
    do {
        if (*pp >= end) break;
        byte = *(*pp)++;
        result |= ((int64_t)(byte & 0x7f)) << shift;
        shift += 7;
    } while (byte & 0x80);
    if (shift < 64 && (byte & 0x40)) {
        result |= -(1LL << shift);
    }
    return result;
}

static uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static bool add_check(uint64_t left, uint64_t right, uint64_t* result) {
    *result = left + right;
    return right <= (UINT64_MAX - left);
}

// ==================== Fat Binary 解析 ====================

// 从 universal binary 中提取 x86-64 切片
static uint8_t* extract_amd64_slice(const uint8_t* data, uint64_t size, uint64_t* out_size) {
    if (size < sizeof(csap_fat_header_t)) {
        return NULL;
    }

    uint32_t magic = read_u32_be(data);
    if (magic != CSAP_FAT_MAGIC) {
        // 不是 fat binary，直接返回原始数据的拷贝
        uint8_t* copy = malloc(size);
        if (copy == NULL) return NULL;
        memcpy(copy, data, size);
        *out_size = size;
        return copy;
    }

    csap_fat_header_t* fh = (csap_fat_header_t*)data;
    uint32_t nfat = read_u32_be((const uint8_t*)&fh->nfat_arch);

    for (uint32_t i = 0; i < nfat; i++) {
        csap_fat_arch_t* arch = (csap_fat_arch_t*)(data + sizeof(csap_fat_header_t) + i * sizeof(csap_fat_arch_t));
        uint32_t cputype = read_u32_be((const uint8_t*)&arch->cputype);
        uint32_t offset = read_u32_be((const uint8_t*)&arch->offset);
        uint32_t asize = read_u32_be((const uint8_t*)&arch->size);

        if (cputype == CSAP_CPU_TYPE_X86_64) {
            if ((uint64_t)offset + asize > size) return NULL;
            uint8_t* copy = malloc(asize);
            if (copy == NULL) return NULL;
            memcpy(copy, data + offset, asize);
            *out_size = asize;
            return copy;
        }
    }

    return NULL;
}

// ==================== Dyld Info 解析 ====================

// Bind opcodes (opcode = high nibble, imm = low nibble)
#define BIND_OPCODE_DONE                             0x00
#define BIND_OPCODE_SET_DYLIB_ORDINAL_IMM            0x10
#define BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB           0x20
#define BIND_OPCODE_SET_DYLIB_SPECIAL_IMM            0x30
#define BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM    0x40
#define BIND_OPCODE_SET_TYPE_IMM                     0x50
#define BIND_OPCODE_SET_ADDEND_SLEB                  0x60
#define BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB      0x70
#define BIND_OPCODE_ADD_ADDR_ULEB                    0x80
#define BIND_OPCODE_DO_BIND                          0x90
#define BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB            0xa0
#define BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED      0xb0
#define BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB 0xc0

// Rebase opcodes (opcode = high nibble, imm = low nibble)
#define REBASE_OPCODE_DONE                               0x00
#define REBASE_OPCODE_SET_TYPE_IMM                       0x10
#define REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB        0x20
#define REBASE_OPCODE_ADD_ADDR_ULEB                      0x30
#define REBASE_OPCODE_ADD_ADDR_IMM_SCALED                0x40
#define REBASE_OPCODE_DO_REBASE_IMM_TIMES                0x50
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES               0x60
#define REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB            0x70
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 0x80

// 解析 bind 信息
static int parse_binds(csap_macho_image_t* image, const uint8_t* bind_data, uint32_t bind_size) {
    if (bind_size == 0) return 0;

    const uint8_t* p = bind_data;
    const uint8_t* end = bind_data + bind_size;

    uint64_t seg_offset = 0;
    uint8_t seg_index = 0;
    int64_t addend = 0;
    uint8_t type = CSAP_BIND_TYPE_POINTER;
    char* symbol = NULL;
    uint32_t cap = 0;

    while (p < end) {
        uint8_t opcode = *p & 0xf0;
        uint8_t imm = *p & 0x0f;
        p++;

        switch (opcode) {
        case BIND_OPCODE_DONE:
            // lazy bind 流中可能有多个 DONE，每个分隔一个条目
            // 重置状态并继续解析
            seg_offset = 0;
            seg_index = 0;
            addend = 0;
            type = CSAP_BIND_TYPE_POINTER;
            free(symbol);
            symbol = NULL;
            continue;

        case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
        case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
            if (opcode == BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB) {
                read_uleb128(&p, end);
            }
            break;

        case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
            // 特殊库 ordinal，imm 低 4 位有符号
            break;

        case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
            // symbol 是尾随的以 null 结尾的字符串
            const char* s = (const char*)p;
            size_t slen = strnlen(s, (size_t)(end - p));
            if (slen >= (size_t)(end - p)) break;
            free(symbol);
            symbol = strdup(s);
            cap = (uint32_t)slen;
            (void)cap;
            p += slen + 1;
            break;
        }

        case BIND_OPCODE_SET_TYPE_IMM:
            type = imm;
            break;

        case BIND_OPCODE_SET_ADDEND_SLEB:
            addend = read_sleb128(&p, end);
            break;

        case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            seg_index = imm;
            seg_offset = read_uleb128(&p, end);
            break;

        case BIND_OPCODE_ADD_ADDR_ULEB:
            seg_offset += read_uleb128(&p, end);
            break;

        case BIND_OPCODE_DO_BIND: {
            if (symbol != NULL) {
                image->binds = realloc(image->binds, (image->bind_count + 1) * sizeof(csap_macho_bind_t));
                csap_macho_bind_t* b = &image->binds[image->bind_count++];
                b->name = strdup(symbol);
                b->seg_offset = seg_offset;
                b->addend = addend;
                b->type = type;
                b->seg_index = seg_index;
            }
            seg_offset += 8;
            break;
        }

        case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: {
            if (symbol != NULL) {
                image->binds = realloc(image->binds, (image->bind_count + 1) * sizeof(csap_macho_bind_t));
                csap_macho_bind_t* b = &image->binds[image->bind_count++];
                b->name = strdup(symbol);
                b->seg_offset = seg_offset;
                b->addend = addend;
                b->type = type;
                b->seg_index = seg_index;
            }
            seg_offset += read_uleb128(&p, end) + 8;
            break;
        }

        case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: {
            if (symbol != NULL) {
                image->binds = realloc(image->binds, (image->bind_count + 1) * sizeof(csap_macho_bind_t));
                csap_macho_bind_t* b = &image->binds[image->bind_count++];
                b->name = strdup(symbol);
                b->seg_offset = seg_offset;
                b->addend = addend;
                b->type = type;
                b->seg_index = seg_index;
            }
            seg_offset += (uint64_t)(imm) * CSAP_POINTER_SIZE + 8;
            break;
        }

        case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
            uint64_t count = read_uleb128(&p, end);
            uint64_t skip = read_uleb128(&p, end);
            for (uint64_t i = 0; i < count && symbol != NULL; i++) {
                image->binds = realloc(image->binds, (image->bind_count + 1) * sizeof(csap_macho_bind_t));
                csap_macho_bind_t* b = &image->binds[image->bind_count++];
                b->name = strdup(symbol);
                b->seg_offset = seg_offset;
                b->addend = addend;
                b->type = type;
                b->seg_index = seg_index;
                seg_offset += skip + 8;
            }
            break;
        }

        default:
            // 未知 opcode，停止
            goto done;
        }
    }
done:
    free(symbol);
    return 0;
}

// 解析 rebase 信息
static int parse_rebases(csap_macho_image_t* image, const uint8_t* rebase_data, uint32_t rebase_size) {
    if (rebase_size == 0) return 0;

    const uint8_t* p = rebase_data;
    const uint8_t* end = rebase_data + rebase_size;

    uint64_t seg_offset = 0;
    uint8_t seg_index = 0;
    uint8_t type = CSAP_REBASE_TYPE_POINTER;

    while (p < end) {
        uint8_t opcode = *p & 0xf0;
        uint8_t imm = *p & 0x0f;
        p++;

        switch (opcode) {
        case REBASE_OPCODE_DONE:
            goto done;

        case REBASE_OPCODE_SET_TYPE_IMM:
            type = imm;
            break;

        case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            seg_index = imm;
            seg_offset = read_uleb128(&p, end);
            break;

        case REBASE_OPCODE_ADD_ADDR_ULEB:
            seg_offset += read_uleb128(&p, end);
            break;

        case REBASE_OPCODE_ADD_ADDR_IMM_SCALED:
            seg_offset += (uint64_t)(imm) * CSAP_POINTER_SIZE;
            break;

        case REBASE_OPCODE_DO_REBASE_IMM_TIMES: {
            uint64_t count = imm;
            for (uint64_t i = 0; i < count; i++) {
                image->rebases = realloc(image->rebases, (image->rebase_count + 1) * sizeof(csap_macho_rebase_t));
                csap_macho_rebase_t* r = &image->rebases[image->rebase_count++];
                r->seg_index = seg_index;
                r->seg_offset = seg_offset;
                r->type = type;
                r->value = 0; // 实际值在 relocate 时计算
                seg_offset += CSAP_POINTER_SIZE;
            }
            break;
        }

        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES: {
            uint64_t count = read_uleb128(&p, end);
            for (uint64_t i = 0; i < count; i++) {
                image->rebases = realloc(image->rebases, (image->rebase_count + 1) * sizeof(csap_macho_rebase_t));
                csap_macho_rebase_t* r = &image->rebases[image->rebase_count++];
                r->seg_index = seg_index;
                r->seg_offset = seg_offset;
                r->type = type;
                r->value = 0;
                seg_offset += CSAP_POINTER_SIZE;
            }
            break;
        }

        case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: {
            image->rebases = realloc(image->rebases, (image->rebase_count + 1) * sizeof(csap_macho_rebase_t));
            csap_macho_rebase_t* r = &image->rebases[image->rebase_count++];
            r->seg_index = seg_index;
            r->seg_offset = seg_offset;
            r->type = type;
            r->value = 0;
            seg_offset += read_uleb128(&p, end) + CSAP_POINTER_SIZE;
            break;
        }

        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: {
            uint64_t count = read_uleb128(&p, end);
            uint64_t skip = read_uleb128(&p, end);
            for (uint64_t i = 0; i < count; i++) {
                image->rebases = realloc(image->rebases, (image->rebase_count + 1) * sizeof(csap_macho_rebase_t));
                csap_macho_rebase_t* r = &image->rebases[image->rebase_count++];
                r->seg_index = seg_index;
                r->seg_offset = seg_offset;
                r->type = type;
                r->value = 0;
                seg_offset += skip + CSAP_POINTER_SIZE;
            }
            break;
        }

        default:
            goto done;
        }
    }
done:
    return 0;
}

// ==================== Export Trie 解析 ====================

// 查找 export trie 中的符号
static uint64_t find_export_symbol(const uint8_t* trie, uint32_t trie_size, const char* name) {
    if (trie == NULL || trie_size == 0) return 0;

    size_t name_len = strlen(name);
    const uint8_t* end = trie + trie_size;
    const uint8_t* node = trie;
    size_t name_idx = 0;

    while (node < end) {
        const uint8_t* p = node;

        // 读取节点大小 (ULEB128) - 不包括自身
        uint64_t node_size = read_uleb128(&p, end);

        // terminal info 区域
        const uint8_t* term_start = p;
        const uint8_t* term_end = p + node_size;

        if (name_idx == name_len) {
            // 精确匹配，解析 terminal info
            if (node_size == 0) return 0;

            const uint8_t* tp = term_start;
            uint64_t flags = read_uleb128(&tp, term_end);

            if (flags & 0x08) {
                // EXPORT_SYMBOL_FLAGS_REEXPORT - 跳过
                return 0;
            } else if (flags & 0x10) {
                // EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER
                return read_uleb128(&tp, term_end);  // stub address
            } else {
                // 普通符号: address
                return read_uleb128(&tp, term_end);
            }
        }

        // 跳过 terminal info，读取子节点数量
        p = term_end;
        if (p >= end) return 0;
        uint8_t child_count = *p++;

        bool found = false;
        for (uint8_t i = 0; i < child_count; i++) {
            if (p >= end) return 0;
            const char* edge = (const char*)p;
            size_t edge_len = strnlen(edge, (size_t)(end - p));
            if (edge_len >= (size_t)(end - p)) return 0;
            p += edge_len + 1;

            uint64_t child_offset = read_uleb128(&p, end);

            if (strncmp(edge, name + name_idx, edge_len) == 0) {
                name_idx += edge_len;
                node = trie + child_offset;
                found = true;
                break;
            }
        }

        if (!found) return 0;
    }

    return 0;
}

// ==================== 公开 API ====================

csap_macho_image_t* csap_macho_open(const char* name, const uint8_t* data, uint64_t size) {
    if (data == NULL || size < sizeof(csap_mh_header_64_t)) {
        return NULL;
    }

    csap_macho_image_t* image = calloc(1, sizeof(csap_macho_image_t));
    if (image == NULL) return NULL;

    image->name = strdup(name ? name : "unknown");

    // 提取 x86-64 切片
    image->data = extract_amd64_slice(data, size, &image->data_size);
    if (image->data == NULL) {
        fprintf(stderr, "csap: %s: failed to extract x86-64 slice\n", image->name);
        csap_macho_free(image);
        return NULL;
    }

    // 验证 Mach-O header
    if (image->data_size < sizeof(csap_mh_header_64_t)) {
        fprintf(stderr, "csap: %s: too small for Mach-O header\n", image->name);
        csap_macho_free(image);
        return NULL;
    }

    csap_mh_header_64_t* hdr = (csap_mh_header_64_t*)image->data;
    if (read_u32_le((const uint8_t*)&hdr->magic) != CSAP_MH_MAGIC_64) {
        fprintf(stderr, "csap: %s: not a 64-bit Mach-O\n", image->name);
        csap_macho_free(image);
        return NULL;
    }
    if (read_u32_le((const uint8_t*)&hdr->cputype) != CSAP_CPU_TYPE_X86_64) {
        fprintf(stderr, "csap: %s: not x86-64 Mach-O\n", image->name);
        csap_macho_free(image);
        return NULL;
    }

    uint32_t ncmds = read_u32_le((const uint8_t*)&hdr->ncmds);
    uint32_t sizeofcmds = read_u32_le((const uint8_t*)&hdr->sizeofcmds);

    // 遍历 load commands
    const uint8_t* lc_ptr = image->data + sizeof(csap_mh_header_64_t);
    const uint8_t* lc_end = lc_ptr + sizeofcmds;

    for (uint32_t i = 0; i < ncmds && lc_ptr < lc_end; i++) {
        csap_load_command_t* lc = (csap_load_command_t*)lc_ptr;
        uint32_t cmd = read_u32_le((const uint8_t*)&lc->cmd);
        uint32_t cmdsize = read_u32_le((const uint8_t*)&lc->cmdsize);

        switch (cmd) {
        case CSAP_LC_SEGMENT_64: {
            csap_segment_command_64_t* seg = (csap_segment_command_64_t*)lc_ptr;
            image->segments = realloc(image->segments, (image->segment_count + 1) * sizeof(csap_macho_segment_t));
            csap_macho_segment_t* s = &image->segments[image->segment_count++];
            memcpy(s->name, seg->segname, 16);
            s->name[15] = '\0';
            s->address = read_u64_le((const uint8_t*)&seg->vmaddr);
            s->size = read_u64_le((const uint8_t*)&seg->vmsize);
            s->file_off = read_u64_le((const uint8_t*)&seg->fileoff);
            s->file_size = read_u64_le((const uint8_t*)&seg->filesize);
            break;
        }

        case CSAP_LC_DYLD_INFO:
        case CSAP_LC_DYLD_INFO_ONLY: {
            csap_dyld_info_command_t* dyld = (csap_dyld_info_command_t*)lc_ptr;
            uint32_t rebase_off = read_u32_le((const uint8_t*)&dyld->rebase_off);
            uint32_t rebase_size = read_u32_le((const uint8_t*)&dyld->rebase_size);
            uint32_t bind_off = read_u32_le((const uint8_t*)&dyld->bind_off);
            uint32_t bind_size = read_u32_le((const uint8_t*)&dyld->bind_size);
            uint32_t weak_bind_off = read_u32_le((const uint8_t*)&dyld->weak_bind_off);
            uint32_t weak_bind_size = read_u32_le((const uint8_t*)&dyld->weak_bind_size);
            uint32_t lazy_bind_off = read_u32_le((const uint8_t*)&dyld->lazy_bind_off);
            uint32_t lazy_bind_size = read_u32_le((const uint8_t*)&dyld->lazy_bind_size);
            uint32_t export_off = read_u32_le((const uint8_t*)&dyld->export_off);
            uint32_t export_size = read_u32_le((const uint8_t*)&dyld->export_size);

            if (rebase_off + rebase_size <= image->data_size && rebase_size > 0) {
                parse_rebases(image, image->data + rebase_off, rebase_size);
            }
            if (bind_off + bind_size <= image->data_size && bind_size > 0) {
                parse_binds(image, image->data + bind_off, bind_size);
            }
            if (weak_bind_off + weak_bind_size <= image->data_size && weak_bind_size > 0) {
                parse_binds(image, image->data + weak_bind_off, weak_bind_size);
            }
            if (lazy_bind_off + lazy_bind_size <= image->data_size && lazy_bind_size > 0) {
                parse_binds(image, image->data + lazy_bind_off, lazy_bind_size);
            }
            if (export_off + export_size <= image->data_size && export_size > 0) {
                image->export_trie = malloc(export_size);
                if (image->export_trie) {
                    memcpy(image->export_trie, image->data + export_off, export_size);
                    image->export_trie_size = export_size;
                }
            }
            break;
        }

        case CSAP_LC_SYMTAB: {
            csap_symtab_command_t* symtab = (csap_symtab_command_t*)lc_ptr;
            uint32_t symoff = read_u32_le((const uint8_t*)&symtab->symoff);
            uint32_t nsyms = read_u32_le((const uint8_t*)&symtab->nsyms);
            uint32_t stroff = read_u32_le((const uint8_t*)&symtab->stroff);
            uint32_t strsize = read_u32_le((const uint8_t*)&symtab->strsize);

            if (symoff + nsyms * sizeof(struct nlist_64) <= image->data_size) {
                image->symtab = malloc(nsyms * sizeof(struct nlist_64));
                if (image->symtab) {
                    memcpy(image->symtab, image->data + symoff, nsyms * sizeof(struct nlist_64));
                    image->symtab_count = nsyms;
                }
            }
            if (stroff + strsize <= image->data_size) {
                image->strtab = malloc(strsize);
                if (image->strtab) {
                    memcpy(image->strtab, image->data + stroff, strsize);
                    image->strtab_size = strsize;
                }
            }
            break;
        }

        default:
            break;
        }

        lc_ptr += cmdsize;
    }

    // 计算 base address（第一个非 __PAGEZERO segment 的地址）
    image->base = 0;
    for (uint32_t i = 0; i < image->segment_count; i++) {
        if (strcmp(image->segments[i].name, "__PAGEZERO") != 0 && image->segments[i].size > 0) {
            image->base = image->segments[i].address;
            break;
        }
    }

    return image;
}

int csap_macho_export(csap_macho_image_t* image, const char* name, uint64_t load_base, uint64_t* out_address) {
    if (image == NULL || name == NULL || out_address == NULL) return -1;

    uint64_t address = 0;

    // 首先尝试 export trie
    if (image->export_trie != NULL) {
        address = find_export_symbol(image->export_trie, image->export_trie_size, name);
    }

    // 如果 export trie 没找到，尝试符号表
    if (address == 0 && image->symtab != NULL && image->strtab != NULL) {
        for (uint32_t i = 0; i < image->symtab_count; i++) {
            struct nlist_64* sym = &image->symtab[i];
            uint32_t strx = read_u32_le((const uint8_t*)&sym->n_strx);
            if (strx >= image->strtab_size) continue;

            const char* symname = image->strtab + strx;
            // 跳过前导下划线
            const char* cmp = symname;
            if (cmp[0] == '_') cmp++;

            if (strcmp(cmp, name) == 0) {
                address = read_u64_le((const uint8_t*)&sym->n_value);
                break;
            }
        }
    }

    if (address == 0) {
        return -1;
    }

    if (address < image->base) {
        return -1;
    }

    uint64_t result;
    if (!add_check(load_base, address - image->base, &result)) {
        return -1;
    }

    *out_address = result;
    return 0;
}

// 查找 segment 在文件中的偏移
static int segment_file_offset(csap_macho_image_t* image, uint8_t seg_index, uint64_t offset, uint64_t size, uint64_t* out_offset) {
    if (seg_index >= image->segment_count) return -1;
    csap_macho_segment_t* seg = &image->segments[seg_index];

    uint64_t seg_end;
    if (!add_check(offset, size, &seg_end)) return -1;
    if (seg_end > seg->size) return -1;

    uint64_t result;
    if (!add_check(seg->file_off, offset, &result)) return -1;

    uint64_t end;
    if (!add_check(result, size, &end)) return -1;
    if (end > image->data_size) return -1;

    *out_offset = result;
    return 0;
}

int csap_macho_relocate(csap_macho_image_t* image, uint64_t load_base,
                        csap_symbol_resolver_t resolver, void* resolver_ctx) {
    if (image == NULL) return -1;
    if (image->relocated) {
        fprintf(stderr, "csap: %s already relocated\n", image->name);
        return -1;
    }

    // 处理 rebases
    for (uint32_t i = 0; i < image->rebase_count; i++) {
        csap_macho_rebase_t* r = &image->rebases[i];
        if (r->type != CSAP_REBASE_TYPE_POINTER) {
            fprintf(stderr, "csap: %s unsupported rebase type %d\n", image->name, r->type);
            return -1;
        }

        uint64_t file_off;
        if (segment_file_offset(image, r->seg_index, r->seg_offset, CSAP_POINTER_SIZE, &file_off) != 0) {
            fprintf(stderr, "csap: %s rebase segment offset error\n", image->name);
            return -1;
        }

        // rebase 值 = load_base + (原始地址 - base)
        // 原始地址存储在该位置，读取它，加上 slide
        uint64_t original = read_u64_le(image->data + file_off);
        uint64_t slide = load_base - image->base;
        uint64_t new_addr = original + slide;

        write_u64_le(image->data + file_off, new_addr);
    }

    // 处理 binds
    for (uint32_t i = 0; i < image->bind_count; i++) {
        csap_macho_bind_t* b = &image->binds[i];

        uint64_t file_off;
        if (segment_file_offset(image, b->seg_index, b->seg_offset, CSAP_POINTER_SIZE, &file_off) != 0) {
            fprintf(stderr, "csap: %s bind segment offset error for %s\n", image->name, b->name);
            return -1;
        }

        uint64_t address = 0;
        if (resolver != NULL) {
            if (resolver(b->name, &address, resolver_ctx) != 0) {
                fprintf(stderr, "csap: %s failed to resolve %s\n", image->name, b->name);
                return -1;
            }
        }

        // 应用 addend
        if (b->addend >= 0) {
            address += (uint64_t)b->addend;
        } else {
            address -= (uint64_t)(-b->addend);
        }

        write_u64_le(image->data + file_off, address);
    }

    image->relocated = true;
    image->loaded_base = load_base;
    return 0;
}

int csap_macho_load(csap_macho_image_t* image,
                    csap_mem_map_fn mem_map, csap_mem_write_fn mem_write, void* mem_ctx) {
    if (image == NULL) return -1;
    if (!image->relocated) {
        fprintf(stderr, "csap: %s must be relocated before loading\n", image->name);
        return -1;
    }

    uint64_t span = 0;
    for (uint32_t i = 0; i < image->segment_count; i++) {
        csap_macho_segment_t* seg = &image->segments[i];
        if (strcmp(seg->name, "__PAGEZERO") == 0 || seg->size == 0) continue;

        uint64_t offset = seg->address - image->base;
        uint64_t end;
        if (!add_check(offset, seg->size, &end)) return -1;
        if (end > CSAP_MAX_IMAGE_SPAN) return -1;

        if (end > span) span = end;
    }

    span = align_up(span, CSAP_PAGE_SIZE);
    if (span == 0) {
        fprintf(stderr, "csap: %s has no loadable segments\n", image->name);
        return -1;
    }

    if (mem_map && mem_map(image->loaded_base, span, mem_ctx) != 0) {
        fprintf(stderr, "csap: %s mem_map failed\n", image->name);
        return -1;
    }

    for (uint32_t i = 0; i < image->segment_count; i++) {
        csap_macho_segment_t* seg = &image->segments[i];
        if (strcmp(seg->name, "__PAGEZERO") == 0 || seg->file_size == 0) continue;

        uint64_t offset = seg->address - image->base;
        uint64_t address;
        if (!add_check(image->loaded_base, offset, &address)) return -1;

        if (mem_write && mem_write(address, image->data + seg->file_off, seg->file_size, mem_ctx) != 0) {
            fprintf(stderr, "csap: %s mem_write failed for segment %s\n", image->name, seg->name);
            return -1;
        }
    }

    return 0;
}

void csap_macho_free(csap_macho_image_t* image) {
    if (image == NULL) return;
    free(image->name);
    free(image->data);
    free(image->segments);
    for (uint32_t i = 0; i < image->bind_count; i++) {
        free(image->binds[i].name);
    }
    free(image->binds);
    free(image->rebases);
    free(image->export_trie);
    free(image->symtab);
    free(image->strtab);
    free(image);
}
