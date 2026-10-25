/* SPDX-License-Identifier: MIT */
#ifndef MCP_INTERNAL_H
#define MCP_INTERNAL_H
#define _GNU_SOURCE
#include "mcp.h"
#include <curl/curl.h>
#include <json-c/json.h>
#include <stdbool.h>
#include <sys/types.h>

typedef struct json_object json;
typedef struct mcp_buffer {
  char *data;
  size_t len, capacity;
} mcp_buffer;
typedef struct mcp_frame {
  char *wire;
  size_t length, offset;
  int64_t id;
  struct mcp_frame *next;
} mcp_frame;

struct mcp_request {
  mcp_client *client;
  struct mcp_request *next;
  int64_t id, deadline;
  int timeout_ms;
  char *method;
  json *params, *input_result, *progress_token, *filter, *ack_filter;
  double progress;
  bool has_progress, subscription, acknowledged, sent;
  mcp_status status;
  mcp_error error;
  mcp_response response;
  mcp_response validation;
  mcp_schema *output_schema;
  CURL *easy;
  struct curl_slist *headers;
  char *post_body;
  mcp_buffer body, sse_line, sse_data, auth_challenge;
  bool json_content_type, sse, sse_skip_lf, sse_first, sse_message, http_done;
  long http_status;
  int transport_code;
  mcp_status receive_error;
  mcp_error receive_detail;
};

struct mcp_client {
  mcp_response handler_error;
  int fd;
  pid_t pid;
  int timeout_ms, shutdown_ms;
  size_t limit, used;
  char *buffer, *name, *version;
  const char *protocol;
  json *capabilities, *client_capabilities, *tools;
  int64_t next_id;
  bool modern, ready, broken, polling, http;
  mcp_message_fn on_message;
  void *context;
  mcp_handler_fn on_request;
  void *request_context;
  size_t max_pending, request_count;
  mcp_request *requests;
  mcp_frame *tx_head, *tx_tail;
  CURLM *multi;
  char *url, *bearer, *auth_challenge;
  long http_status;
  int transport_code;
};

mcp_status mcp_fail(mcp_error *, mcp_status, int, const char *);
int64_t mcp_now(void);
bool mcp_has(json *, const char *);
json *mcp_field(json *, const char *);
bool mcp_string_is(json *, const char *);
bool mcp_add(json *, const char *, json *);
mcp_status mcp_parse(const char *, size_t, json **, mcp_error *);
mcp_status mcp_buffer_append(mcp_buffer *, const char *, size_t, size_t,
                             mcp_error *);
void mcp_buffer_free(mcp_buffer *);
mcp_status mcp_dispatch(mcp_client *, mcp_request *origin, const char *, size_t,
                        mcp_error *);
mcp_status mcp_retain_failure(mcp_client *, mcp_request *, const char *, size_t,
                              mcp_error *);
void mcp_finish(mcp_request *, mcp_status, const mcp_error *);
mcp_request *mcp_find(mcp_client *, int64_t);
mcp_status mcp_queue(mcp_client *, json *, int64_t, mcp_error *);
mcp_status mcp_stdio_open(mcp_client *, const mcp_options *, mcp_error *);
mcp_status mcp_stdio_close(mcp_client *, mcp_error *);
mcp_status mcp_stdio_poll(mcp_client *, int, mcp_error *);
mcp_status mcp_stdio_cancel(mcp_request *, const char *, mcp_error *);
mcp_status mcp_http_init(mcp_client *, const char *, const char *, mcp_error *);
mcp_status mcp_http_submit(mcp_request *, json *, mcp_error *);
mcp_status mcp_http_poll(mcp_client *, int, mcp_error *);
void mcp_http_remove(mcp_request *);
void mcp_http_close(mcp_client *);
mcp_status mcp_http_cache_tools(mcp_client *, json *, mcp_error *);
json *mcp_identity(mcp_client *);
bool mcp_retired(mcp_client *, int64_t);
mcp_schema *mcp_schema_clone(const mcp_schema *);
mcp_status mcp_schema_result(mcp_request *, json *, mcp_error *);
mcp_status mcp_validate_phase(const mcp_schema *, const char *, const char *, mcp_response *, mcp_error *);
struct mcp_tool {
  char *name;
  mcp_schema *input, *output;
};
bool mcp_filter_valid(json *);
mcp_status mcp_invoke(mcp_client *, const char *, json *, json **, bool *,
                      mcp_error *);

#endif
