#include "mcp.h"
#include <assert.h>
#include <errno.h>
#include <string.h>
static int fail_poll;
mcp_status __real_mcp_stdio_poll(mcp_client *, int, mcp_error *);
mcp_status __wrap_mcp_stdio_poll(mcp_client *c, int ms, mcp_error *e) {
  if (!fail_poll)
    return __real_mcp_stdio_poll(c, ms, e);
  if (e)
    *e = (mcp_error){.code = MCP_SYSTEM_ERROR,
                     .system_errno = EIO,
                     .message = "injected I/O failure"};
  return MCP_SYSTEM_ERROR;
}
int main(int argc, char **argv) {
  assert(argc == 3);
  const char *args[] = {argv[1], argv[2], "modern", NULL};
  mcp_options o;
  mcp_options_init(&o);
  o.command = args[0];
  o.argv = args;
  mcp_client *c = NULL;
  mcp_response response = {0};
  mcp_error e = {0};
  assert(mcp_client_open(&o, &c, &response, &e) == MCP_OK);
  mcp_response_free(&response);
  mcp_request *a = NULL, *b = NULL;
  assert(mcp_client_submit(c, "ping", NULL, 100, &a, &e) == MCP_OK);
  assert(mcp_client_submit(c, "ping", NULL, 100, &b, &e) == MCP_OK);
  fail_poll = 1;
  assert(mcp_request_cancel(a, "done", &e) == MCP_SYSTEM_ERROR);
  assert(mcp_request_status(b) == MCP_SYSTEM_ERROR);
  assert(mcp_request_take(b, &response, &e) == MCP_SYSTEM_ERROR);
  assert(e.system_errno == EIO && !strcmp(e.message, "injected I/O failure"));
  fail_poll = 0;
  assert(mcp_request_destroy(a, &e) == MCP_OK);
  assert(mcp_request_destroy(b, &e) == MCP_OK);
  assert(mcp_client_close(c, &e) == MCP_OK);
  return 0;
}
