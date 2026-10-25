module libmcp;

// The C ABI declared in libmcp/include/mcp.h. No druntime and no GC ownership.
// mcp_response.json is freed by mcp_response_free, including on error returns.

enum MCP_VERSION = "0.4.0-dev";
enum MCP_PROTOCOL_VERSION = "2026-07-28";

extern (C) nothrow @nogc {
    struct mcp_client;
    enum mcp_status : int {
        MCP_OK = 0, MCP_INVALID_ARGUMENT, MCP_NO_MEMORY, MCP_SYSTEM_ERROR,
        MCP_TIMEOUT, MCP_EOF, MCP_PROTOCOL_ERROR, MCP_REMOTE_ERROR,
        MCP_INVALID_STATE, MCP_MESSAGE_TOO_LARGE, MCP_INPUT_REQUIRED,
        MCP_TOOL_ERROR, MCP_UNSUPPORTED, MCP_PENDING, MCP_CANCELLED,
        MCP_HTTP_ERROR, MCP_AUTH_REQUIRED, MCP_SCHEMA_ERROR, MCP_VALIDATION_ERROR, MCP_VALIDATION_LIMIT
    }
    enum mcp_protocol : int { MCP_PROTOCOL_AUTO = 0, MCP_PROTOCOL_MODERN, MCP_PROTOCOL_LEGACY }

    struct mcp_error {
        mcp_status code;
        int system_errno;
        int child_status;
        mcp_status cleanup_code;
        int cleanup_errno;
        int cleanup_child_status;
        const(char)* message;
        const(char)* cleanup_message;
    }
    struct mcp_response { char* json; size_t length; long error_code; }
    alias mcp_message_fn = void function(void*, const(char)*, size_t) nothrow @nogc;

    struct mcp_options {
        const(char)* command;
        const(char*)* argv;
        const(char*)* envp;
        const(char)* cwd;
        const(char)* client_name;
        const(char)* client_version;
        mcp_protocol protocol;
        int timeout_ms;
        int probe_timeout_ms;
        int shutdown_timeout_ms;
        size_t max_message_bytes;
        mcp_message_fn on_message;
        void* context;
    }

    // 0.2: poll-driven requests, host features, HTTP. Declared as mcp.h has
    // them; ground calls none of them yet.
    struct mcp_request;
    struct mcp_schema;
    struct mcp_tool;
    struct mcp_schema_options {
        size_t max_bytes;
        uint max_depth;
        uint pattern_timeout_ms;
        const(char)* resources_json;
    }
    void mcp_schema_options_init(mcp_schema_options*);
    mcp_status mcp_schema_compile(const(char)*, const(mcp_schema_options)*, mcp_schema**, mcp_response*, mcp_error*);
    mcp_status mcp_schema_validate(const(mcp_schema)*, const(char)*, mcp_response*, mcp_error*);
    void mcp_schema_destroy(mcp_schema*);
    mcp_status mcp_tool_compile(const(char)*, const(mcp_schema_options)*, mcp_tool**, mcp_response*, mcp_error*);
    void mcp_tool_destroy(mcp_tool*);
    const(char)* mcp_tool_name(const(mcp_tool)*);
    mcp_status mcp_tool_submit(mcp_client*, const(mcp_tool)*, const(char)*, int, mcp_request**, mcp_error*);
    mcp_status mcp_tool_call(mcp_client*, const(mcp_tool)*, const(char)*, mcp_response*, mcp_response*, mcp_error*);
    const(char)* mcp_request_validation_json(const(mcp_request)*);
    const(char)* mcp_request_auth_challenge(const(mcp_request)*);
    long mcp_request_http_status(const(mcp_request)*);
    int mcp_request_transport_code(const(mcp_request)*);
    alias mcp_handler_fn = mcp_status function(void*, const(char)*, const(char)*, mcp_response*, mcp_error*) nothrow @nogc;
    struct mcp_features {
        const(char)* capabilities_json;
        mcp_handler_fn on_request;
        void* context;
        size_t max_pending;
    }
    void mcp_features_init(mcp_features*);
    mcp_status mcp_response_set(mcp_response*, const(char)*, mcp_error*);
    mcp_status mcp_client_open_ex(const(mcp_options)*, const(mcp_features)*, mcp_client**, mcp_response*, mcp_error*);
    mcp_status mcp_client_open_http(const(mcp_options)*, const(mcp_features)*, const(char)*, const(char)*, mcp_client**, mcp_response*, mcp_error*);
    mcp_status mcp_client_create_http(const(mcp_options)*, const(mcp_features)*, const(char)*, const(char)*, mcp_client**, mcp_error*);
    mcp_status mcp_client_set_bearer(mcp_client*, const(char)*, mcp_error*);
    const(char)* mcp_client_auth_challenge(const(mcp_client)*);
    int mcp_client_transport_code(const(mcp_client)*);
    // C long is 64 bits on the supported LP64 Linux/macOS platforms.
    long mcp_client_http_status(const(mcp_client)*);
    mcp_status mcp_client_tools_catalog(mcp_client*, mcp_response*, mcp_error*);
    mcp_status mcp_client_submit(mcp_client*, const(char)*, const(char)*, int, mcp_request**, mcp_error*);
    mcp_status mcp_client_poll(mcp_client*, int, mcp_error*);
    long mcp_request_id(const(mcp_request)*);
    mcp_status mcp_request_status(const(mcp_request)*);
    mcp_status mcp_request_take(mcp_request*, mcp_response*, mcp_error*);
    mcp_status mcp_request_cancel(mcp_request*, const(char)*, mcp_error*);
    mcp_status mcp_request_resume(mcp_request*, const(char)*, mcp_error*);
    mcp_status mcp_request_destroy(mcp_request*, mcp_error*);
    mcp_status mcp_client_call(mcp_client*, const(char)*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_resource_templates_list(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_completion_complete(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_subscriptions_listen(mcp_client*, const(char)*, mcp_request**, mcp_error*);
    mcp_status mcp_resources_subscribe(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_resources_unsubscribe(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_logging_set_level(mcp_client*, const(char)*, mcp_response*, mcp_error*);

    void mcp_options_init(mcp_options*);
    const(char)* mcp_version();
    const(char)* mcp_status_string(mcp_status);
    void mcp_response_free(mcp_response*);
    mcp_status mcp_client_open(const(mcp_options)*, mcp_client**, mcp_response*, mcp_error*);
    const(char)* mcp_client_protocol_version(const(mcp_client)*);
    mcp_status mcp_client_request(mcp_client*, const(char)*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_tools_list(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_tools_call(mcp_client*, const(char)*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_resources_list(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_resources_read(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_prompts_list(mcp_client*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_prompts_get(mcp_client*, const(char)*, const(char)*, mcp_response*, mcp_error*);
    mcp_status mcp_client_close(mcp_client*, mcp_error*);
}
