// Exercise the same D dispatch API that Ground's provider loop can call.
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.reply : Reply;
import libmcp;
import core.stdc.stdio : stdout, stderr, fputs, fwrite;
import core.stdc.string : strlen;

extern(C) int main(int argc, const(char)** argv) {
    if (argc != 2) return 2;
    McpGroup group;
    Reply detail;
    scope(exit) detail.dispose();
    auto config = argv[1][0 .. strlen(argv[1])];
    if (!openMcp(config, "/tmp", group, detail)) {
        auto text = detail.slice(); fwrite(text.ptr, 1, text.length, stderr); return 1;
    }
    mcp_response response, validation;
    mcp_error error;
    auto status = callMcpTool(group, "test", "echo", `{"text":"harness"}`, response, validation, error);
    if (response.json !is null) fwrite(response.json, 1, response.length, stdout);
    mcp_response_free(&response);
    mcp_response_free(&validation);
    bool closed = closeMcp(group, detail);
    return status == mcp_status.MCP_OK && closed ? 0 : 1;
}
