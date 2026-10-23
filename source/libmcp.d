module libmcp;

// The C ABI declared in libmcp/include/mcp.h. No druntime and no GC ownership.
// mcp_response.json is freed by mcp_response_free, including on error returns.

enum MCP_VERSION = "0.1.0";
enum MCP_PROTOCOL_VERSION = "2026-07-28";

extern (C) nothrow @nogc {
    struct mcp_client;
    enum mcp_status : int {
        MCP_OK = 0, MCP_INVALID_ARGUMENT, MCP_NO_MEMORY, MCP_SYSTEM_ERROR,
        MCP_TIMEOUT, MCP_EOF, MCP_PROTOCOL_ERROR, MCP_REMOTE_ERROR,
        MCP_INVALID_STATE, MCP_MESSAGE_TOO_LARGE, MCP_INPUT_REQUIRED,
        MCP_TOOL_ERROR, MCP_UNSUPPORTED
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
