#ifndef CSAP_MACHIMAGE_H
#define CSAP_MACHIMAGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CSAP_PAGE_SIZE      0x1000
#define CSAP_MAX_IMAGE_SPAN (1ULL << 30)
#define CSAP_POINTER_SIZE   8

// Mach-O magic numbers
#define CSAP_MH_MAGIC_64    0xfeedfacf
#define CSAP_FAT_MAGIC      0xcafebabe
#define CSAP_FAT_MAGIC_64   0xcafebabf

// CPU types
#define CSAP_CPU_TYPE_X86_64 0x01000007

// Load commands
#define CSAP_LC_SEGMENT_64       0x19
#define CSAP_LC_DYLD_INFO        0x22
#define CSAP_LC_DYLD_INFO_ONLY   0x80000022
#define CSAP_LC_SYMTAB           0x02
#define CSAP_LC_DYSYMTAB         0x0b

// Bind types
#define CSAP_BIND_TYPE_POINTER    1
#define CSAP_REBASE_TYPE_POINTER  1

// Segment info
typedef struct {
    char     name[16];
    uint64_t address;
    uint64_t size;
    uint64_t file_off;
    uint64_t file_size;
} csap_macho_segment_t;

// Bind info
typedef struct {
    char*    name;
    uint64_t seg_offset;
    int64_t  addend;
    uint8_t  type;
    uint8_t  seg_index;  // segment index in image
} csap_macho_bind_t;

// Rebase info
typedef struct {
    uint64_t value;
    uint8_t  type;
    uint8_t  seg_index;
    uint64_t seg_offset;
} csap_macho_rebase_t;

// Mach-O image
typedef struct {
    char*                 name;
    uint8_t*              data;
    uint64_t              data_size;
    uint64_t              base;
    csap_macho_segment_t* segments;
    uint32_t              segment_count;
    csap_macho_bind_t*    binds;
    uint32_t              bind_count;
    csap_macho_rebase_t*  rebases;
    uint32_t              rebase_count;
    bool                  relocated;
    uint64_t              loaded_base;

    // export trie data
    uint8_t*              export_trie;
    uint32_t              export_trie_size;

    // symbol table
    struct nlist_64*      symtab;
    uint32_t              symtab_count;
    char*                 strtab;
    uint32_t              strtab_size;
} csap_macho_image_t;

// Symbol resolver callback
typedef int (*csap_symbol_resolver_t)(const char* name, uint64_t* address, void* ctx);

// Memory interface
typedef int (*csap_mem_map_fn)(uint64_t address, uint64_t size, void* ctx);
typedef int (*csap_mem_write_fn)(uint64_t address, const void* data, uint64_t size, void* ctx);

// Open and parse a Mach-O image
csap_macho_image_t* csap_macho_open(const char* name, const uint8_t* data, uint64_t size);

// Find an exported symbol address (relative to load_base)
int csap_macho_export(csap_macho_image_t* image, const char* name, uint64_t load_base, uint64_t* out_address);

// Apply relocations (rebases + binds)
int csap_macho_relocate(csap_macho_image_t* image, uint64_t load_base,
                        csap_symbol_resolver_t resolver, void* resolver_ctx);

// Load image into memory
int csap_macho_load(csap_macho_image_t* image,
                    csap_mem_map_fn mem_map, csap_mem_write_fn mem_write, void* mem_ctx);

// Free image
void csap_macho_free(csap_macho_image_t* image);

#ifdef __cplusplus
}
#endif

#endif // CSAP_MACHIMAGE_H
