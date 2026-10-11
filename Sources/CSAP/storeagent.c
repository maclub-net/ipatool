#include "storeagent.h"
#include "shims.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct csap_storeagent {
    csap_machine_t* machine;
    uint64_t session;
    int closed;
};

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

static const char* zero_return_aliases[] = {
    "_pthread_rwlock_rdlock",
    "_pthread_rwlock_rdlock$UNIX2003",
    "_pthread_mutex_init",
    "_pthread_mutex_destroy",
    "_pthread_rwlock_destroy",
};

// ==================== 内部辅助 ====================

static csap_storeagent_t* create_agent(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* storeagent_data, size_t storeagent_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    uint32_t* out_global_context) {

    uint8_t hardware[24];
    if (make_hardware_block(hardware_id, hardware_id_len, hardware) != 0) {
        fprintf(stderr, "csap: invalid hardware ID\n");
        return NULL;
    }

    csap_extra_image_t extra = {
        .name = "storeagent",
        .data = storeagent_data,
        .size = storeagent_size,
        .base = CSAP_STOREAGENT_BASE,
    };

    csap_extra_shims_t extra_shims = {
        .names = zero_return_aliases,
        .count = sizeof(zero_return_aliases) / sizeof(zero_return_aliases[0]),
    };

    csap_machine_t* machine = csap_machine_open_extended(
        corefp_data, corefp_size,
        commercecore_data, commercecore_size,
        commercekit_data, commercekit_size,
        icxs_data, icxs_size,
        &extra, 1,
        &extra_shims);

    if (machine == NULL) {
        fprintf(stderr, "csap: failed to open StoreAgent machine\n");
        return NULL;
    }

    csap_storeagent_t* agent = calloc(1, sizeof(csap_storeagent_t));
    if (agent == NULL) {
        csap_machine_close(machine);
        return NULL;
    }
    agent->machine = machine;

    // 初始化全局上下文
    csap_machine_begin_call(machine);

    uint64_t hw_addr = csap_machine_scratch(machine, hardware, 24);
    if (hw_addr == 0) goto fail;

    const char* scinfo_path = CSAP_STOREAGENT_SCINFO_PATH;
    size_t path_len = strlen(scinfo_path) + 1;
    uint64_t path_addr = csap_machine_scratch(machine, (const uint8_t*)scinfo_path, path_len);
    if (path_addr == 0) goto fail;

    uint64_t context_field = csap_machine_scratch(machine, NULL, 4);
    if (context_field == 0) goto fail;

    uint64_t args[4] = {0, hw_addr, path_addr, context_field};
    uint64_t status;
    if (csap_machine_invoke(machine, CSAP_STOREAGENT_GLOBAL_INIT, args, 4, &status) != 0) {
        goto fail;
    }

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: StoreAgent global init returned %d\n", (int32_t)status);
        goto fail;
    }

    uint32_t global_context = csap_machine_read_u32(machine, context_field);
    if (global_context == 0) {
        fprintf(stderr, "csap: StoreAgent global init returned null context\n");
        goto fail;
    }

    csap_machine_clear_scratch(machine);

    if (out_global_context) *out_global_context = global_context;
    return agent;

fail:
    csap_machine_clear_scratch(machine);
    csap_machine_close(machine);
    free(agent);
    return NULL;
}

// ==================== Open ====================

csap_storeagent_t* csap_storeagent_open(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* storeagent_data, size_t storeagent_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    const uint8_t* dp_info, size_t dp_info_len) {

    if (dp_info == NULL || dp_info_len == 0) {
        fprintf(stderr, "csap: StoreAgent dpInfo is empty\n");
        return NULL;
    }

    uint32_t global_context = 0;
    csap_storeagent_t* agent = create_agent(
        corefp_data, corefp_size,
        commercecore_data, commercecore_size,
        commercekit_data, commercekit_size,
        icxs_data, icxs_size,
        storeagent_data, storeagent_size,
        hardware_id, hardware_id_len,
        &global_context);

    if (agent == NULL) return NULL;

    // 初始化会话
    csap_machine_t* machine = agent->machine;
    csap_machine_begin_call(machine);

    uint64_t dp_addr = csap_machine_scratch(machine, dp_info, dp_info_len);
    if (dp_addr == 0) goto fail;

    uint64_t session_field = csap_machine_scratch(machine, NULL, 8);
    if (session_field == 0) goto fail;

    uint64_t args[5] = {
        (uint64_t)global_context,
        dp_addr,
        (uint64_t)dp_info_len,
        session_field,
        0,
    };
    uint64_t status;
    if (csap_machine_invoke(machine, CSAP_STOREAGENT_SESSION_INIT, args, 4, &status) != 0) {
        goto fail;
    }

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: StoreAgent session init returned %d\n", (int32_t)status);
        goto fail;
    }

    uint64_t session = csap_machine_read_u64(machine, session_field);
    if (session == 0) {
        fprintf(stderr, "csap: StoreAgent session init returned null session\n");
        goto fail;
    }

    agent->session = session;
    csap_machine_clear_scratch(machine);
    return agent;

fail:
    csap_machine_clear_scratch(machine);
    csap_storeagent_close(agent);
    return NULL;
}

// ==================== KBSync ====================

int csap_storeagent_generate_kbsync(
    const uint8_t* corefp_data, size_t corefp_size,
    const uint8_t* commercecore_data, size_t commercecore_size,
    const uint8_t* commercekit_data, size_t commercekit_size,
    const uint8_t* icxs_data, size_t icxs_size,
    const uint8_t* storeagent_data, size_t storeagent_size,
    const uint8_t* hardware_id, size_t hardware_id_len,
    uint64_t dsid,
    uint8_t** out_kbsync, size_t* out_kbsync_len) {

    if (dsid == 0) {
        fprintf(stderr, "csap: kbsync requires nonzero DSID\n");
        return -1;
    }

    uint32_t global_context = 0;
    csap_storeagent_t* agent = create_agent(
        corefp_data, corefp_size,
        commercecore_data, commercecore_size,
        commercekit_data, commercekit_size,
        icxs_data, icxs_size,
        storeagent_data, storeagent_size,
        hardware_id, hardware_id_len,
        &global_context);

    if (agent == NULL) return -1;

    csap_machine_t* machine = agent->machine;
    csap_machine_begin_call(machine);

    uint64_t pointer_field = csap_machine_scratch(machine, NULL, 8);
    if (pointer_field == 0) goto fail;

    uint64_t length_field = csap_machine_scratch(machine, NULL, 8);
    if (length_field == 0) goto fail;

    uint64_t args[6] = {
        (uint64_t)global_context,
        dsid,
        0,
        1,
        pointer_field,
        length_field,
    };
    uint64_t status;
    if (csap_machine_invoke(machine, CSAP_STOREAGENT_KBSYNC_ENTRY, args, 6, &status) != 0) {
        goto fail;
    }

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: kbsync returned %d\n", (int32_t)status);
        goto fail;
    }

    uint64_t pointer = csap_machine_read_u64(machine, pointer_field);
    uint64_t length = csap_machine_read_u64(machine, length_field);

    if (length == 0 || pointer == 0) {
        fprintf(stderr, "csap: kbsync returned empty buffer\n");
        goto fail;
    }

    uint8_t* output = malloc(length);
    if (output == NULL) goto fail;
    if (csap_machine_read_mem(machine, pointer, output, length) != 0) {
        free(output);
        goto fail;
    }

    csap_machine_dispose(machine, pointer);
    csap_machine_clear_scratch(machine);
    csap_storeagent_close(agent);

    if (out_kbsync) *out_kbsync = output;
    else free(output);
    if (out_kbsync_len) *out_kbsync_len = length;
    return 0;

fail:
    csap_machine_clear_scratch(machine);
    csap_storeagent_close(agent);
    return -1;
}

// ==================== Decrypt ====================

int csap_storeagent_decrypt_chunk(csap_storeagent_t* agent, uint8_t* data, size_t size) {
    if (agent == NULL || agent->closed) return -1;
    if (data == NULL || size == 0) return 0;

    csap_machine_t* machine = agent->machine;
    csap_machine_begin_call(machine);

    uint64_t addr = csap_machine_scratch(machine, data, size);
    if (addr == 0) goto fail;

    uint64_t args[5] = {
        agent->session,
        addr,
        (uint64_t)size,
        addr,
        0,
    };
    uint64_t status;
    if (csap_machine_invoke(machine, CSAP_STOREAGENT_DECRYPT_ENTRY, args, 5, &status) != 0) {
        goto fail;
    }

    if ((int32_t)status != 0) {
        fprintf(stderr, "csap: StoreAgent decrypt returned %d\n", (int32_t)status);
        goto fail;
    }

    if (csap_machine_read_mem(machine, addr, data, size) != 0) {
        goto fail;
    }

    csap_machine_clear_scratch(machine);
    return 0;

fail:
    csap_machine_clear_scratch(machine);
    return -1;
}

// ==================== Close ====================

void csap_storeagent_close(csap_storeagent_t* agent) {
    if (agent == NULL || agent->closed) return;
    agent->closed = 1;

    if (agent->machine != NULL && agent->session != 0) {
        uint64_t args[1] = {agent->session};
        uint64_t status;
        csap_machine_invoke(agent->machine, CSAP_STOREAGENT_SESSION_CLOSE, args, 1, &status);
        agent->session = 0;
    }

    if (agent->machine != NULL) {
        csap_machine_close(agent->machine);
        agent->machine = NULL;
    }

    free(agent);
}
