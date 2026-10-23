#include "mcp.h"
#include <stddef.h>

size_t mcp_test_layout(unsigned i) {
    const size_t values[] = {
        sizeof(mcp_options), sizeof(mcp_error), sizeof(mcp_response),
        offsetof(mcp_options, command), offsetof(mcp_options, argv),
        offsetof(mcp_options, envp), offsetof(mcp_options, cwd),
        offsetof(mcp_options, client_name), offsetof(mcp_options, client_version),
        offsetof(mcp_options, protocol), offsetof(mcp_options, timeout_ms),
        offsetof(mcp_options, probe_timeout_ms), offsetof(mcp_options, shutdown_timeout_ms),
        offsetof(mcp_options, max_message_bytes), offsetof(mcp_options, on_message),
        offsetof(mcp_options, context), offsetof(mcp_error, message), offsetof(mcp_error, cleanup_message),
        offsetof(mcp_response, length), offsetof(mcp_response, error_code)
    };
    return i < sizeof(values) / sizeof(values[0]) ? values[i] : (size_t)-1;
}
