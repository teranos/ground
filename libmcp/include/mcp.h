/* SPDX-License-Identifier: MIT */
#ifndef LIBMCP_H
#define LIBMCP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MCP_VERSION "0.1.0"
#define MCP_PROTOCOL_VERSION "2026-07-28"

typedef struct mcp_client mcp_client;

typedef enum mcp_status {
    MCP_OK = 0,
    MCP_INVALID_ARGUMENT,
    MCP_NO_MEMORY,
    MCP_SYSTEM_ERROR,
    MCP_TIMEOUT,
    MCP_EOF,
    MCP_PROTOCOL_ERROR,
    MCP_REMOTE_ERROR,
    MCP_INVALID_STATE,
    MCP_MESSAGE_TOO_LARGE,
    MCP_INPUT_REQUIRED,
    MCP_TOOL_ERROR,
    MCP_UNSUPPORTED
} mcp_status;

typedef enum mcp_protocol {
    MCP_PROTOCOL_AUTO = 0,
    MCP_PROTOCOL_MODERN,
    MCP_PROTOCOL_LEGACY
} mcp_protocol;

/* message is static storage. errno is captured at the failing system call.
 * Remote errors, including their message and data, live in mcp_response.json. */
typedef struct mcp_error {
    mcp_status code;
    int system_errno;
    int child_status; /* raw waitpid status, zero unless reporting child exit */
    mcp_status cleanup_code; /* secondary failure while rolling back open */
    int cleanup_errno;
    int cleanup_child_status;
    const char *message;
    const char *cleanup_message;
} mcp_error;

/* Initialize to {0}. Free before reusing. json is the complete received frame,
 * byte for byte, without its final LF (or CRLF); free only with this library.
 * A response can be populated on non-OK returns. Never discard it unchecked. */
typedef struct mcp_response {
    char *json;
    size_t length;
    int64_t error_code;
} mcp_response;

/* Borrowed frame, valid during the callback. Called for notifications and for
 * legacy server requests before ping/MethodNotFound is sent. No reentry into
 * this client; callbacks must return promptly (they share the call deadline). */
typedef void (*mcp_message_fn)(void *context, const char *json, size_t length);

typedef struct mcp_options {
    const char *command;
    const char *const *argv; /* NULL-terminated, including argv[0]; no shell */
    const char *const *envp; /* NULL inherits environment; otherwise replaces it */
    const char *cwd;        /* NULL inherits working directory */
    const char *client_name;
    const char *client_version;
    mcp_protocol protocol;
    int timeout_ms;
    int probe_timeout_ms;
    int shutdown_timeout_ms;
    size_t max_message_bytes;
    mcp_message_fn on_message;
    void *context;
} mcp_options;

void mcp_options_init(mcp_options *options);
const char *mcp_version(void);
const char *mcp_status_string(mcp_status status);
void mcp_response_free(mcp_response *response);

/* Opens and negotiates. On failure *out is NULL and any handshake response is
 * still owned by the caller. The child inherits stderr. Linux and macOS.
 * One call at a time per client; independent clients may run concurrently. */
mcp_status mcp_client_open(const mcp_options *options, mcp_client **out,
                           mcp_response *handshake, mcp_error *error);
const char *mcp_client_protocol_version(const mcp_client *client);

/* params_json must be a JSON object, or NULL for {}. _meta protocol fields
 * are added for modern peers. The caller owns pagination and MRTR retries.
 * A timeout/I/O/protocol/size failure makes the connection unusable: close it.
 * Calls are never automatically retried. Valid remote/tool/input errors leave
 * it usable. No HTTP, OAuth, schema validation or LLM execution is implicit. */
mcp_status mcp_client_request(mcp_client *client, const char *method,
                              const char *params_json, mcp_response *response,
                              mcp_error *error);
mcp_status mcp_tools_list(mcp_client *, const char *cursor, mcp_response *, mcp_error *);
mcp_status mcp_tools_call(mcp_client *, const char *name, const char *arguments_json,
                          mcp_response *, mcp_error *);
mcp_status mcp_resources_list(mcp_client *, const char *cursor, mcp_response *, mcp_error *);
mcp_status mcp_resources_read(mcp_client *, const char *uri, mcp_response *, mcp_error *);
mcp_status mcp_prompts_list(mcp_client *, const char *cursor, mcp_response *, mcp_error *);
mcp_status mcp_prompts_get(mcp_client *, const char *name, const char *arguments_json,
                           mcp_response *, mcp_error *);

/* Consumes the handle, including on error. EOF, wait, TERM, wait, KILL, reap.
 * The grace interval applies separately before TERM and before KILL.
 * Forced shutdown and a nonzero child exit are reported, never called success. */
mcp_status mcp_client_close(mcp_client *client, mcp_error *error);

#ifdef __cplusplus
}
#endif
#endif
