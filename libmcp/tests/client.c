#define _POSIX_C_SOURCE 200809L
#include "mcp.h"
#include <assert.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>

/* Link and run as an ordinary embedding C process, with SIGPIPE at default.
 * Also used under ASan/UBSan/LSan to check both success and failure cleanup. */
int main(int argc, char **argv) {
    assert(argc == 3);
    struct sigaction reset = {0};
    reset.sa_handler = SIG_DFL;
    assert(sigaction(SIGPIPE, &reset, NULL) == 0);
    struct sigaction before, after;
    assert(sigaction(SIGPIPE, NULL, &before) == 0);
    const char *args[] = {argv[1], argv[2], "modern", NULL};
    mcp_options options;
    mcp_options_init(&options);
    options.command = args[0]; options.argv = args;
    mcp_client *client = NULL;
    mcp_response response = {0};
    mcp_error error = {0};
    assert(mcp_client_open(&options, &client, &response, &error) == MCP_OK);
    mcp_response_free(&response);
    assert(mcp_tools_list(client, NULL, &response, &error) == MCP_OK);
    mcp_response_free(&response);
    assert(mcp_tools_call(client, "echo", "{\"text\":\"☃\"}", &response, &error) == MCP_OK);
    mcp_response_free(&response);
    assert(mcp_client_request(client, "test/remote", "{}", &response, &error) == MCP_REMOTE_ERROR);
    assert(response.error_code == -32001 && response.json != NULL);
    mcp_response_free(&response);
    assert(mcp_client_close(client, &error) == MCP_OK);
    args[2] = "exit-after-discover";
    assert(mcp_client_open(&options, &client, &response, &error) == MCP_OK);
    mcp_response_free(&response);
    struct timespec pause = {0, 100000000};
    nanosleep(&pause, NULL);
    mcp_status status = mcp_tools_list(client, NULL, &response, &error);
    assert(status == MCP_SYSTEM_ERROR || status == MCP_EOF);
    mcp_response_free(&response);
    assert(mcp_client_close(client, &error) == MCP_OK);
    assert(sigaction(SIGPIPE, NULL, &after) == 0);
    assert(before.sa_handler == after.sa_handler);
    assert(waitpid(-1, NULL, WNOHANG) == -1); /* every owned child was reaped */
    puts("C static linkage, remote error ownership, SIGPIPE and reaping passed");
    return 0;
}
