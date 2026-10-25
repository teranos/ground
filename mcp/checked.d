// The actual Ground dispatch boundary: rejected model arguments never execute.
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.reply : Reply;
import libmcp;
import core.stdc.string : strlen, strstr;
import core.stdc.stdio : puts, fwrite, stderr;
extern(C) int main(int argc, const(char)** argv) {
    assert(argc == 2);
    McpGroup group;
    Reply detail;
    scope(exit) detail.dispose();
    if (!openMcp(argv[1][0 .. strlen(argv[1])], "/tmp", group, detail)) {
        fwrite(detail.slice().ptr, 1, detail.len, stderr); return 1;
    }
    mcp_response response, validation;
    mcp_error error;
    auto status = callMcpTool(group, "test", "echo", `{"text":42}`, response, validation, error);
    assert(status == mcp_status.MCP_VALIDATION_ERROR);
    assert(response.json is null);
    assert(validation.json !is null && strstr(validation.json, "/text") !is null);
    mcp_response_free(&validation);
    status = callMcpTool(group, "test", "echo", `{"text":"corrected"}`, response, validation, error);
    assert(status == mcp_status.MCP_OK);
    assert(strstr(response.json, "corrected") !is null);
    mcp_response_free(&response);
    status = callMcpTool(group, "test", "bad-output", `{"text":"bad"}`, response, validation, error);
    assert(status == mcp_status.MCP_VALIDATION_ERROR);
    assert(response.json !is null && validation.json !is null);
    assert(strstr(validation.json, "output") !is null);
    mcp_response_free(&response); mcp_response_free(&validation);
    assert(closeMcp(group, detail));
    puts("Ground checked dispatch: invalid input, corrected call, invalid output, cleanup passed");
    return 0;
}
