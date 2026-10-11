#ifndef CSAP_H
#define CSAP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CSAP_SUPPORTED_VERSION 200

// SAP 配置
typedef struct {
    uint32_t version;
} csap_config_t;

// SAP 签名器（不透明类型）
typedef struct csap_signer csap_signer_t;

// 创建签名器
// 加载 SAP 资产，打开机器，执行 initialize
// 返回的签名器已完成 initialize，但还需要 exchange 完成 setup
csap_signer_t* csap_signer_create(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    uint32_t version);

// 执行 SAP exchange
// 第一次：input = 证书数据，out_result 应为 1，out_output 为 setup request
// 第二次：input = setup reply，out_result 应为 0
int csap_signer_exchange(csap_signer_t* signer,
                         const uint8_t* input, size_t input_len,
                         uint8_t** out_output, size_t* out_output_len,
                         int32_t* out_result);

// 签名
int csap_signer_sign(csap_signer_t* signer,
                     const uint8_t* input, size_t input_len,
                     uint8_t** output, size_t* output_len);

// 释放签名器（执行 teardown）
void csap_signer_free(csap_signer_t* signer);

// 释放 C 分配的内存
void csap_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif // CSAP_H
