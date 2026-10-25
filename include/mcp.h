/* SPDX-License-Identifier: MIT */
#ifndef LIBMCP_H
#define LIBMCP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MCP_VERSION "0.4.0-dev"
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
    MCP_UNSUPPORTED,
    MCP_PENDING,
    MCP_CANCELLED,
    MCP_HTTP_ERROR,
    MCP_AUTH_REQUIRED,
    MCP_SCHEMA_ERROR,
    MCP_VALIDATION_ERROR,
    MCP_VALIDATION_LIMIT
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
 * byte for byte, without its final LF (or CRLF); explicit host/catalog helpers
 * instead return their documented JSON values. Free only with this library.
 * A response can be populated on non-OK returns. Never discard it unchecked. */
typedef struct mcp_response {
    char *json;
    size_t length;
    int64_t error_code;
} mcp_response;

/* Borrowed frame, valid during the callback. Called for notifications and for
 * legacy server requests before their reply is sent. No reentry into
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

typedef struct mcp_request mcp_request;
typedef struct mcp_schema mcp_schema;
typedef struct mcp_tool mcp_tool;

/* Initialize with mcp_schema_options_init. Zero limits are invalid. External
 * references resolve ONLY from resources_json, an object mapping absolute URIs
 * to schema values, copied during compilation. No network or file fetching.
 * max_depth bounds in-place evaluator recursion; pattern_timeout_ms bounds
 * each regex match, NOT the whole evaluation. max_bytes bounds each input and
 * report. These are resource limits, not a wall-clock execution guarantee. */
typedef struct mcp_schema_options {
    size_t max_bytes;
    unsigned max_depth;
    unsigned pattern_timeout_ms;
    const char *resources_json;
} mcp_schema_options;

void mcp_schema_options_init(mcp_schema_options *);
/* report must be empty, and is library-owned JSON freed with response_free.
 * Schema errors, invalid instances and abandoned evaluations are distinct.
 * Draft 2020-12 is the default. format is an annotation unless the dialect
 * requires assertion. Compilation checks the schema against its metaschema.
 * No defaults, coercions or mutation of the instance. */
mcp_status mcp_schema_compile(const char *, const mcp_schema_options *,
                              mcp_schema **, mcp_response *report, mcp_error *);
mcp_status mcp_schema_validate(const mcp_schema *, const char *instance_json,
                               mcp_response *report, mcp_error *);
void mcp_schema_destroy(mcp_schema *);
/* Compile a tools/list tool definition; inputSchema is required. Keep the
 * definition associated with the server that supplied it. A submitted request
 * retains its output schema independently of the tool handle's lifetime. */
mcp_status mcp_tool_compile(const char *, const mcp_schema_options *, mcp_tool **,
                            mcp_response *report, mcp_error *);
void mcp_tool_destroy(mcp_tool *);
const char *mcp_tool_name(const mcp_tool *);
mcp_status mcp_tool_submit(mcp_client *, const mcp_tool *, const char *arguments,
                           int timeout_ms, mcp_request **, mcp_error *);
/* A successful submit can return an already-completed validation failure;
 * inspect status. Invalid input sends no bytes. Validation JSON is borrowed,
 * survives take, and is released on resume/destroy/client close. */
const char *mcp_request_validation_json(const mcp_request *);
mcp_status mcp_tool_call(mcp_client *, const mcp_tool *, const char *arguments,
                         mcp_response *, mcp_response *report, mcp_error *);

/* Handler output is a result object, or an error object for MCP_REMOTE_ERROR.
 * Use mcp_response_set to copy it into library-owned storage. A handler only
 * runs for explicitly declared capabilities. It may decline without retrying.
 * Callbacks run on the polling thread; no reentry into the same client. */
typedef mcp_status (*mcp_handler_fn)(void *context, const char *method,
                                   const char *params_json, mcp_response *result,
                                   mcp_error *error);
typedef struct mcp_features {
    const char *capabilities_json;
    mcp_handler_fn on_request;
    void *context;
    size_t max_pending;
} mcp_features;

void mcp_features_init(mcp_features *features);
mcp_status mcp_response_set(mcp_response *, const char *json, mcp_error *);
mcp_status mcp_client_open_ex(const mcp_options *, const mcp_features *,
                              mcp_client **, mcp_response *, mcp_error *);
/* Modern Streamable HTTP. TLS verification is mandatory; redirects are not
 * followed. HTTP is permitted only for loopback endpoints. OAuth flows remain
 * host-owned: bearer tokens are scoped to this exact endpoint, never forwarded
 * to redirects. 401/403 bodies and WWW-Authenticate are retained for the host. */
mcp_status mcp_client_open_http(const mcp_options *, const mcp_features *,
                                const char *url, const char *bearer_token,
                                mcp_client **, mcp_response *, mcp_error *);
/* Create a stateless endpoint without network I/O. Issue server/discover with
 * mcp_client_request to retain initial auth challenges on a live client. A
 * successful discovery installs capabilities for the convenience helpers. */
mcp_status mcp_client_create_http(const mcp_options *, const mcp_features *,
                                  const char *url, const char *bearer_token,
                                  mcp_client **, mcp_error *);
mcp_status mcp_client_set_bearer(mcp_client *, const char *token, mcp_error *);
/* Filtered HTTP tool catalog; raw tools/list responses remain byte-exact.
 * Invalid header annotations are excluded here. Refresh tools/list before use. */
mcp_status mcp_client_tools_catalog(mcp_client *, mcp_response *, mcp_error *);
/* Compatibility accessors: client-wide last-observed values, potentially from
 * different transfers. Use request diagnostics for concurrent operations. */
const char *mcp_client_auth_challenge(const mcp_client *);
long mcp_client_http_status(const mcp_client *);
int mcp_client_transport_code(const mcp_client *);

/* submit queues a request without waiting for the server. timeout_ms must be
 * positive and is per-request. poll(0) never waits; poll(n) waits at most n ms,
 * bounded by the earliest request deadline. libMCP owns no worker threads;
 * libcurl may use resolver threads.
 * Acknowledged subscriptions live until cancelled, completed, or disconnected.
 * Request handles belong to their client and become invalid when it closes. */
mcp_status mcp_client_submit(mcp_client *, const char *method, const char *params,
                             int timeout_ms, mcp_request **, mcp_error *);
mcp_status mcp_client_poll(mcp_client *, int timeout_ms, mcp_error *);
int64_t mcp_request_id(const mcp_request *);
mcp_status mcp_request_status(const mcp_request *);
/* Diagnostics for this request's current HTTP round. Zero/NULL for NULL,
 * stdio, or values not yet observed. Inspect after completion; values can
 * change while pending. transport_code is a libcurl CURLcode, not errno;
 * zero does not imply success (e.g. cancellation before a transfer finishes).
 * The challenge is borrowed, with repeated WWW-Authenticate fields joined by
 * ", " in wire order, bounded in aggregate by max_message_bytes. It is not
 * parsed. Only the latest HTTP header block is retained. A failed transfer
 * can have partial diagnostics. Copy anything needed beyond resume/destroy
 * or client close. take does not consume diagnostics; a new continuation
 * round resets them. No automatic authentication retry is performed. */
const char *mcp_request_auth_challenge(const mcp_request *);
long mcp_request_http_status(const mcp_request *);
int mcp_request_transport_code(const mcp_request *);
mcp_status mcp_request_take(mcp_request *, mcp_response *, mcp_error *);
mcp_status mcp_request_cancel(mcp_request *, const char *reason, mcp_error *);
mcp_status mcp_request_resume(mcp_request *, const char *input_responses, mcp_error *);
mcp_status mcp_request_destroy(mcp_request *, mcp_error *);
/* Optional synchronous MRTR helper. Invokes declared feature handlers and
 * echoes opaque requestState with a fresh RPC id for each continuation.
 * On a host handler failure, response contains that handler's JSON error
 * object when supplied, preserving its message and data.
 * The whole conversation shares the original timeout; no tool is retried on
 * transport errors. If no handler is installed, INPUT_REQUIRED is returned. */
mcp_status mcp_client_call(mcp_client *, const char *method, const char *params,
                           mcp_response *, mcp_error *);

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
 * A timeout cancels only that request. Stdio I/O/protocol failures require close.
 * Calls are never automatically retried. Valid remote/tool/input errors leave
 * it usable. OAuth, schema validation and LLM execution remain host-owned. */
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
mcp_status mcp_resource_templates_list(mcp_client *, const char *, mcp_response *, mcp_error *);
mcp_status mcp_completion_complete(mcp_client *, const char *params_json, mcp_response *, mcp_error *);
mcp_status mcp_subscriptions_listen(mcp_client *, const char *filter_json, mcp_request **, mcp_error *);
mcp_status mcp_resources_subscribe(mcp_client *, const char *uri, mcp_response *, mcp_error *);
mcp_status mcp_resources_unsubscribe(mcp_client *, const char *uri, mcp_response *, mcp_error *);
mcp_status mcp_logging_set_level(mcp_client *, const char *level, mcp_response *, mcp_error *);

/* Consumes the handle, including on error. EOF, wait, TERM, wait, KILL, reap.
 * The grace interval applies separately before TERM and before KILL.
 * Forced shutdown and a nonzero child exit are reported, never called success. */
mcp_status mcp_client_close(mcp_client *client, mcp_error *error);

#ifdef __cplusplus
}
#endif
#endif
