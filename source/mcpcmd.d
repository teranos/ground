module mcpcmd;

import libmcp;
import core.stdc.stdio : stdout, stderr, fwrite, fputs, fprintf;
import core.stdc.string : strcmp, strerror;

enum BOOK_COMMAND = q"EOS
# list tools from a stdio MCP server, in-process through libmcp:
ground mcp tools/list '{}' -- /path/to/server arg
# call a tool (no shell is used to start the server):
ground mcp tools/call '{"name":"echo","arguments":{"text":"hello"}}' -- /path/to/server
EOS";

private extern(C) void ground_mcp_cli_log(void*, const(char)* json, size_t length) nothrow @nogc {
    fputs("ground mcp received: ", stderr);
    fwrite(json, 1, length, stderr);
    fputs("\n", stderr);
}

private void report(ref const mcp_error error) {
    fputs("ground mcp: ", stderr);
    fputs(mcp_status_string(error.code), stderr);
    fputs(": ", stderr);
    if (error.message !is null) fputs(error.message, stderr);
    if (error.system_errno != 0)
        fprintf(stderr, " (errno=%d: %s)", error.system_errno, strerror(error.system_errno));
    if (error.child_status != 0) fprintf(stderr, " (waitpid status=%d)", error.child_status);
    fputs("\n", stderr);
    if (error.cleanup_code != mcp_status.MCP_OK)
        fprintf(stderr, "ground mcp cleanup: %s (errno=%d, waitpid status=%d)\n", error.cleanup_message, error.cleanup_errno, error.cleanup_child_status);
}

private bool output(ref const mcp_response response) {
    if (response.json is null) return true;
    return fwrite(response.json, 1, response.length, stdout) == response.length && fputs("\n", stdout) >= 0;
}

int handleMcp(int argc, const(char)** argv) { return runMcp(argc, argv, 2); }

// Shared by ground and the independently linked -betterC example. offset is
// the method's argv index; argv[argc] is the C ABI's terminating null pointer.
int runMcp(int argc, const(char)** argv, int offset) {
    if (argc < offset + 4 || strcmp(argv[offset + 2], "--") != 0) {
        fputs("usage: ground mcp METHOD PARAMS_JSON -- SERVER [ARG...]\n", stderr);
        return 2;
    }
    mcp_options options;
    mcp_options_init(&options);
    options.command = argv[offset + 3];
    options.argv = cast(const(char*)*) (argv + offset + 3);
    options.client_name = "ground";
    options.on_message = &ground_mcp_cli_log;
    mcp_client* client;
    mcp_response response;
    mcp_error error;
    auto status = mcp_client_open(&options, &client, &response, &error);
    if (status != mcp_status.MCP_OK) {
        report(error);
        if (!output(response)) fputs("ground mcp: failed writing handshake response to stdout\n", stderr);
        mcp_response_free(&response);
        return 1;
    }
    mcp_response_free(&response);
    status = mcp_client_request(client, argv[offset], argv[offset + 1], &response, &error);
    int result = status == mcp_status.MCP_OK ? 0 : 1;
    if (result != 0) report(error);
    if (!output(response)) {
        fputs("ground mcp: failed writing response to stdout\n", stderr);
        result = 1;
    }
    mcp_response_free(&response);
    if (mcp_client_close(client, &error) != mcp_status.MCP_OK) {
        report(error);
        result = 1;
    }
    return result;
}
