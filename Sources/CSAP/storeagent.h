#ifndef CSAP_STOREAGENT_H
#define CSAP_STOREAGENT_H

#include <stdint.h>
#include <stddef.h>
#include "machine.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CSAP_STOREAGENT_BASE         0x00001000c0000000ULL
#define CSAP_STOREAGENT_GLOBAL_INIT  (CSAP_STOREAGENT_BASE + 0x0c5fc0)
#define CSAP_STOREAGENT_KBSYNC_ENTRY (CSAP_STOREAGENT_BASE + 0x0c93c0)
#define CSAP_STOREAGENT_SESSION_INIT (CSAP_STOREAGENT_BASE + 0x0debd0)
#define CSAP_STOREAGENT_DECRYPT_ENTRY (CSAP_STOREAGENT_BASE + 0x0ee700)
#define CSAP_STOREAGENT_SESSION_CLOSE (CSAP_STOREAGENT_BASE + 0x1212d0)
#define CSAP_STOREAGENT_CHUNK_SIZE   0x8000
#define CSAP_STOREAGENT_SCINFO_PATH  "/Users/Shared/SC Info"

typedef struct csap_storeagent csap_storeagent_t;

// 打开 StoreAgent（初始化全局上下文和会话）
csap_storeagent_t* csap_storeagent_open(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* storeagent_data, size_t storeagent_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    const uint8_t* dp_info, size_t dp_info_len);

// 生成 kbsync 数据
int csap_storeagent_generate_kbsync(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* storeagent_data, size_t storeagent_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    uint64_t dsid,
    uint8_t** out_kbsync, size_t* out_kbsync_len);

// 解密一块数据（原地解密）
int csap_storeagent_decrypt_chunk(csap_storeagent_t* agent, uint8_t* data, size_t size);

// 关闭 StoreAgent
void csap_storeagent_close(csap_storeagent_t* agent);

#ifdef __cplusplus
}
#endif

#endif // CSAP_STOREAGENT_H
