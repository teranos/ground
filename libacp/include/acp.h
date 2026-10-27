#ifndef ACP_H
#define ACP_H

// libacp: the Agent Client Protocol, agent side, in C11 with a C ABI.
// v1 at schema-v1.26.0, v2 at schema-v2.0.0-alpha.9: https://agentclientprotocol.com

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ACP_VERSION "0.1.0-dev"

#define ACP_ERROR_INVALID_PARAMS (-32602)
// A requested version none of the supported ones fits:
// "If none exists, it MUST return -32022 with requested and supported data"
#define ACP_ERROR_UNSUPPORTED_VERSION (-32022)

typedef enum acp_status {
    ACP_OK = 0,
    ACP_INVALID_ARGUMENT,
    ACP_NO_MEMORY,
    ACP_PARSE_ERROR,
    ACP_INVALID_PARAMS,
    ACP_UNSUPPORTED_VERSION
} acp_status;

// JSON libacp wrote. The caller owns it and frees it with acp_buffer_free.
typedef struct acp_buffer {
    char *data;
    size_t length;
} acp_buffer;

// What a client offers, read in the shape of the version it requested; 1 offered, 0 not.
// v2 offers only elicitation and auth.
typedef struct acp_client_capabilities {
    int fs_read_text_file;
    int fs_write_text_file;
    int terminal;
    int session_notices;
    int elicitation_form;
    int elicitation_url;
} acp_client_capabilities;

typedef struct acp_initialize {
    unsigned requested_version; // what the client asked for
    unsigned selected_version;  // the highest supported at or below it
    acp_client_capabilities capabilities;
} acp_initialize;

const char *acp_version(void);
const char *acp_status_string(acp_status status);
void acp_buffer_free(acp_buffer *buffer);

// Reads initialize's params and selects the version the connection speaks, from supported.
// On ACP_INVALID_PARAMS or ACP_UNSUPPORTED_VERSION, error_json is the JSON-RPC error to answer.
acp_status acp_initialize_read(const char *params_json, size_t length,
                               const unsigned *supported, size_t supported_count,
                               acp_initialize *out, acp_buffer *error_json);

// The initialize result in the selected version's shape.
// Capabilities and auth methods are JSON the caller writes for that version; NULL is {} and [].
acp_status acp_initialize_result(unsigned selected_version,
                                 const char *agent_name, const char *agent_version,
                                 const char *agent_capabilities_json,
                                 const char *auth_methods_json,
                                 acp_buffer *result_json);

#ifdef __cplusplus
}
#endif

#endif
