// "Upon receiving this notification, the Agent SHOULD: ... Abort all tool call
// invocations in progress". A call the turn is told to stop is cancelled at
// the server, not waited out, and the server's client goes on working.
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.reply : Reply;
import libmcp;
import core.stdc.string : strlen, strstr;
import core.stdc.stdio : puts, fwrite, stderr;
import core.sys.posix.time : clock_gettime, timespec, CLOCK_MONOTONIC;

private long ms() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1_000_000;
}

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
    auto began = ms();
    bool asked = false;
    bool stop() { asked = true; return ms() - began >= 300; }
    auto status = callMcpTool(group, "test", "wait", `{}`, response, validation, error, &stop);
    auto took = ms() - began;
    assert(asked);
    assert(status == mcp_status.MCP_CANCELLED);
    assert(took >= 300 && took < 3000);
    assert(response.json is null);
    mcp_response_free(&validation);
    // Never asked to stop, a call is answered as before.
    status = callMcpTool(group, "test", "quick", `{}`, response, validation, error);
    assert(status == mcp_status.MCP_OK);
    assert(strstr(response.json, "quick") !is null);
    mcp_response_free(&response); mcp_response_free(&validation);
    assert(closeMcp(group, detail));
    puts("Ground tool abort: a stopped call is cancelled at the server within a poll, and the server goes on answering");
    return 0;
}
