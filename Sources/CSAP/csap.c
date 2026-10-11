#include "csap.h"
#include "machine.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct csap_signer {
    csap_machine_t* machine;
    uint64_t context;
    uint8_t* hardware;
    size_t hardware_len;
    uint32_t version;
    int closed;
};

csap_signer_t* csap_signer_create(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    uint32_t version) {

    if (version != CSAP_SUPPORTED_VERSION) {
        fprintf(stderr, "csap: unsupported version %d\n", version);
        return NULL;
    }
    if (hardware_id == NULL || hardware_id_len == 0 || hardware_id_len > 20) {
        fprintf(stderr, "csap: invalid hardware ID\n");
        return NULL;
    }

    csap_machine_t* machine = csap_machine_open(
        corefp_data, corefp_size,
        commercecore_data, commercecore_size,
        commercekit_data, commercekit_size,
        icxs_data, icxs_size);

    if (machine == NULL) {
        fprintf(stderr, "csap: failed to open machine\n");
        return NULL;
    }

    csap_signer_t* signer = calloc(1, sizeof(csap_signer_t));
    if (signer == NULL) {
        csap_machine_close(machine);
        return NULL;
    }

    signer->machine = machine;
    signer->version = version;
    signer->hardware = malloc(hardware_id_len);
    if (signer->hardware == NULL) {
        csap_machine_close(machine);
        free(signer);
        return NULL;
    }
    memcpy(signer->hardware, hardware_id, hardware_id_len);
    signer->hardware_len = hardware_id_len;

    // 初始化会话
    uint64_t context = 0;
    if (csap_machine_initialize(machine, hardware_id, hardware_id_len, &context) != 0) {
        fprintf(stderr, "csap: initialize failed\n");
        csap_signer_free(signer);
        return NULL;
    }
    signer->context = context;

    return signer;
}

int csap_signer_exchange(csap_signer_t* signer,
                         const uint8_t* input, size_t input_len,
                         uint8_t** out_output, size_t* out_output_len,
                         int32_t* out_result) {
    if (signer == NULL || signer->closed) return -1;
    if (input == NULL) return -1;

    uint8_t* output = NULL;
    size_t output_len = 0;
    int32_t result = 0;

    int ret = csap_machine_exchange(
        signer->machine,
        signer->version,
        signer->hardware, signer->hardware_len,
        signer->context,
        input, input_len,
        &output, &output_len,
        &result);

    if (ret != 0) return -1;

    if (out_output) *out_output = output;
    else free(output);
    if (out_output_len) *out_output_len = output_len;
    if (out_result) *out_result = result;

    return 0;
}

int csap_signer_sign(csap_signer_t* signer,
                     const uint8_t* input, size_t input_len,
                     uint8_t** output, size_t* output_len) {
    if (signer == NULL || signer->closed) return -1;
    if (input == NULL) return -1;

    return csap_machine_sign(signer->machine, signer->context,
                             input, input_len, output, output_len);
}

void csap_signer_free(csap_signer_t* signer) {
    if (signer == NULL) return;
    if (signer->closed) return;
    signer->closed = 1;

    // teardown
    if (signer->machine != NULL && signer->context != 0) {
        csap_machine_teardown(signer->machine, signer->context);
        signer->context = 0;
    }

    if (signer->machine != NULL) {
        csap_machine_close(signer->machine);
        signer->machine = NULL;
    }

    if (signer->hardware != NULL) {
        memset(signer->hardware, 0, signer->hardware_len);
        free(signer->hardware);
        signer->hardware = NULL;
    }

    free(signer);
}

void csap_free(void* ptr) {
    free(ptr);
}
