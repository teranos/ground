/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

const char *mcp_version(void) { return MCP_VERSION; }
const char *mcp_status_string(mcp_status s) {
  static const char *const names[] = {"success",
                                      "invalid argument",
                                      "out of memory",
                                      "system error",
                                      "timeout",
                                      "end of stream",
                                      "protocol error",
                                      "remote JSON-RPC error",
                                      "invalid state",
                                      "message too large",
                                      "input required",
                                      "tool error",
                                      "unsupported",
                                      "pending",
                                      "cancelled",
                                      "HTTP error",
                                      "authorization required",
                                      "invalid schema",
                                      "schema validation failed",
                                      "schema evaluation limit"};
  return (unsigned)s < sizeof(names) / sizeof(*names) ? names[s]
                                                      : "unknown status";
}
void mcp_options_init(mcp_options *o) {
  if (o)
    *o = (mcp_options){.client_name = "libmcp",
                       .client_version = MCP_VERSION,
                       .timeout_ms = 30000,
                       .probe_timeout_ms = 500,
                       .shutdown_timeout_ms = 1000,
                       .max_message_bytes = 1024 * 1024};
}
void mcp_features_init(mcp_features *f) {
  if (f)
    *f = (mcp_features){.capabilities_json = "{}", .max_pending = 64};
}
void mcp_response_free(mcp_response *r) {
  if (r) {
    free(r->json);
    *r = (mcp_response){0};
  }
}
mcp_status mcp_response_set(mcp_response *r, const char *text, mcp_error *e) {
  if (!r || r->json || !text)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "response must be empty and JSON must be present");
  json *value = NULL;
  mcp_status s = mcp_parse(text, strlen(text), &value, e);
  json_object_put(value);
  if (s != MCP_OK)
    return s;
  r->length = strlen(text);
  r->json = strdup(text);
  return r->json ? mcp_fail(e, MCP_OK, 0, "success")
                 : mcp_fail(e, MCP_NO_MEMORY, 0, "copy response JSON");
}
int64_t mcp_now(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0)
    return -1;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
json *mcp_identity(mcp_client *c) {
  json *o = json_object_new_object();
  if (!mcp_add(o, "name", json_object_new_string(c->name)) ||
      !mcp_add(o, "version", json_object_new_string(c->version))) {
    json_object_put(o);
    return NULL;
  }
  return o;
}
mcp_request *mcp_find(mcp_client *c, int64_t id) {
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->id == id)
      return r;
  return NULL;
}
void mcp_finish(mcp_request *r, mcp_status s, const mcp_error *e) {
  r->status = s;
  r->error = e ? *e : (mcp_error){.code = s, .message = mcp_status_string(s)};
}
static void break_client(mcp_client *c, mcp_status s, const mcp_error *e) {
  c->broken = true;
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->status == MCP_PENDING)
      mcp_finish(r, s, e);
}
/* IDs are monotonic and never reused. Any inactive issued ID is stale; this
 * remains bounded even after arbitrarily many cancellations or continuations.
 */
bool mcp_retired(mcp_client *c, int64_t id) {
  return id > 0 && id <= c->next_id;
}

static mcp_status build_message(mcp_request *r, json **out, mcp_error *e) {
  mcp_client *c = r->client;
  json *p = NULL;
  if (json_object_deep_copy(r->params, &p, NULL) != 0)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "copy request parameters");
  bool ok = true;
  if (c->modern) {
    json *meta = mcp_field(p, "_meta");
    if (!meta) {
      meta = json_object_new_object();
      ok = mcp_add(p, "_meta", meta);
    }
    if (ok)
      ok = mcp_add(meta, "io.modelcontextprotocol/protocolVersion",
                   json_object_new_string(c->protocol)) &&
           mcp_add(meta, "io.modelcontextprotocol/clientCapabilities",
                   json_object_get(c->client_capabilities)) &&
           mcp_add(meta, "io.modelcontextprotocol/clientInfo", mcp_identity(c));
  }
  json *o = json_object_new_object();
  ok = ok && mcp_add(o, "jsonrpc", json_object_new_string("2.0")) &&
       mcp_add(o, "id", json_object_new_int64(r->id)) &&
       mcp_add(o, "method", json_object_new_string(r->method));
  if (ok)
    ok = mcp_add(o, "params", p);
  else
    json_object_put(p);
  if (!ok) {
    json_object_put(o);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "build request envelope");
  }
  *out = o;
  return MCP_OK;
}
static mcp_status start(mcp_request *r, mcp_error *e) {
  json *o = NULL;
  mcp_status s = build_message(r, &o, e);
  if (s == MCP_OK)
    s = r->client->http ? mcp_http_submit(r, o, e)
                        : mcp_queue(r->client, o, r->id, e);
  json_object_put(o);
  return s;
}
static mcp_status submit(mcp_client *c, const char *method, const char *text,
                         int ms, mcp_request **out, mcp_error *e,
                         const mcp_tool *tool, const char *arguments) {
  if (out)
    *out = NULL;
  if (!c || !method || !*method || !out || ms <= 0)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "invalid request arguments or nonpositive timeout");
  if (c->broken || c->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "client is disconnected or callback attempted reentry");
  if (c->request_count >= c->max_pending)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0,
                    "client request-handle limit reached");
  if (c->next_id == INT64_MAX)
    return mcp_fail(e, MCP_INVALID_STATE, 0, "request id exhausted");
  json *p = NULL;
  mcp_status s = mcp_parse(text ? text : "{}", text ? strlen(text) : 2, &p, e);
  if (s != MCP_OK) {
    if (s == MCP_PROTOCOL_ERROR)
      s = mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                   "request parameters are not valid JSON");
    return s;
  }
  json *meta = mcp_field(p, "_meta"), *unused;
  if (!json_object_is_type(p, json_type_object) ||
      (json_object_object_get_ex(p, "_meta", &unused) &&
       !json_object_is_type(meta, json_type_object))) {
    json_object_put(p);
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "parameters and _meta must be objects");
  }
  json *token = mcp_field(meta, "progressToken");
  if (mcp_has(meta, "progressToken")) {
    if (!json_object_is_type(token, json_type_int) &&
        !json_object_is_type(token, json_type_string)) {
      json_object_put(p);
      return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                      "progress token must be a string or integer");
    }
    for (mcp_request *q = c->requests; q; q = q->next)
      if (q->status == MCP_PENDING && q->progress_token &&
          json_object_equal(q->progress_token, token)) {
        json_object_put(p);
        return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                        "progress token already belongs to an active request");
      }
  }
  bool subscription = !strcmp(method, "subscriptions/listen");
  json *filter = mcp_field(p, "notifications");
  if (subscription && (!c->modern || !mcp_filter_valid(filter))) {
    json_object_put(p);
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "subscriptions/listen needs a modern peer and a valid "
                    "notifications filter");
  }
  mcp_request *r = calloc(1, sizeof(*r));
  if (!r) {
    json_object_put(p);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate request handle");
  }
  r->client = c;
  r->method = strdup(method);
  r->params = p;
  r->id = ++c->next_id;
  r->timeout_ms = ms;
  r->deadline = mcp_now();
  if (!r->method || r->deadline < 0) {
    bool clock_failed = r->deadline < 0;
    free(r->method);
    free(r);
    json_object_put(p);
    return mcp_fail(e, clock_failed ? MCP_SYSTEM_ERROR : MCP_NO_MEMORY, errno,
                    "initialize request handle");
  }
  r->deadline += ms;
  r->status = MCP_PENDING;
  r->subscription = subscription;
  r->filter = json_object_get(filter);
  r->progress_token = json_object_get(token);
  r->sse_first = true;
  r->next = c->requests;
  c->requests = r;
  c->request_count++;
  if (tool) {
    s = mcp_validate_phase(tool->input, arguments, "input", &r->validation, e);
    if (s == MCP_OK && tool->output) {
      r->output_schema = mcp_schema_clone(tool->output);
      if (!r->output_schema) s = mcp_fail(e, MCP_NO_MEMORY, 0, "retain tool output schema");
    }
    if (s == MCP_OK) {
      int64_t now = mcp_now();
      if (now < 0) s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "read request clock");
      else if (now >= r->deadline)
        s = mcp_fail(e, MCP_TIMEOUT, 0, "deadline elapsed during input validation");
    }
    if (s != MCP_OK) {
      mcp_finish(r, s, e);
      *out = r;
      return mcp_fail(e, MCP_OK, 0, "request completed locally; inspect status");
    }
  }
  s = start(r, e);
  if (s != MCP_OK) {
    mcp_finish(r, s, e);
    mcp_request_destroy(r, NULL);
    return s;
  }
  *out = r;
  return mcp_fail(e, MCP_OK, 0, "success");
}
mcp_status mcp_client_submit(mcp_client *c, const char *m, const char *p,
                             int ms, mcp_request **r, mcp_error *e) {
  if (!c || !c->ready) {
    if (r)
      *r = NULL;
    return mcp_fail(e, MCP_INVALID_STATE, 0, "client is not initialized");
  }
  return submit(c, m, p, ms, r, e, NULL, NULL);
}
const char *mcp_request_validation_json(const mcp_request *r) {
  return r ? r->validation.json : NULL;
}
mcp_status mcp_tool_submit(mcp_client *c, const mcp_tool *tool, const char *args,
                           int ms, mcp_request **out, mcp_error *e) {
  if (out) *out = NULL;
  if (!c || !c->ready || !tool || !out)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "tool submit needs a ready client and compiled tool");
  if (!args) args = "{}";
  if (strnlen(args, c->limit + 1) > c->limit)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "tool arguments exceed client byte limit");
  json *arguments = NULL;
  mcp_status s = mcp_parse(args, strlen(args), &arguments, e);
  if (s) return s;
  if (!json_object_is_type(arguments, json_type_object)) {
    json_object_put(arguments);
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "tool arguments must be an object");
  }
  json *p = json_object_new_object();
  bool ok = mcp_add(p, "arguments", arguments) && mcp_add(p, "name", json_object_new_string(tool->name));
  const char *wire = ok ? json_object_to_json_string_ext(p, JSON_C_TO_STRING_PLAIN) : NULL;
  s = wire ? submit(c, "tools/call", wire, ms, out, e, tool, args)
    : mcp_fail(e, MCP_NO_MEMORY, 0, "build checked tool request");
  json_object_put(p);
  return s;
}
int64_t mcp_request_id(const mcp_request *r) { return r ? r->id : 0; }
mcp_status mcp_request_status(const mcp_request *r) {
  return r ? r->status : MCP_INVALID_ARGUMENT;
}
const char *mcp_request_auth_challenge(const mcp_request *r) {
  return r ? r->auth_challenge.data : NULL;
}
long mcp_request_http_status(const mcp_request *r) {
  return r ? r->http_status : 0;
}
int mcp_request_transport_code(const mcp_request *r) {
  return r ? r->transport_code : 0;
}
mcp_status mcp_request_take(mcp_request *r, mcp_response *out, mcp_error *e) {
  if (!r || !out || out->json)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "invalid request or nonempty output");
  if (r->status == MCP_PENDING)
    return mcp_fail(e, MCP_PENDING, 0, "request is pending");
  *out = r->response;
  r->response = (mcp_response){0};
  if (e)
    *e = r->error;
  return r->status;
}

static mcp_status cancel(mcp_request *r, const char *reason,
                         mcp_status terminal, mcp_error *e) {
  if (!r || r->client->polling)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "invalid cancellation or callback reentry");
  if (r->status != MCP_PENDING)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "only an active request can be cancelled");
  mcp_status s = MCP_OK;
  if (r->client->http)
    mcp_http_remove(r);
  else
    s = mcp_stdio_cancel(r, reason, e);
  mcp_finish(r, s == MCP_OK ? terminal : s, s == MCP_OK ? NULL : e);
  return s == MCP_OK ? mcp_fail(e, MCP_OK, 0, "success") : s;
}
mcp_status mcp_request_cancel(mcp_request *r, const char *reason,
                              mcp_error *e) {
  mcp_status s = cancel(r, reason, MCP_CANCELLED, e);
  if (s == MCP_OK && !r->client->http && !r->client->broken) {
    mcp_error flushed = {0};
    r->client->polling = true;
    s = mcp_stdio_poll(r->client, 0, &flushed);
    r->client->polling = false;
    if (s != MCP_OK) {
      if (e)
        *e = flushed;
      break_client(r->client, s, &flushed);
    }
  }
  return s;
}
mcp_status mcp_request_resume(mcp_request *r, const char *text, mcp_error *e) {
  if (!r || r->status != MCP_INPUT_REQUIRED || !r->input_result ||
      r->client->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0, "request is not awaiting input");
  int64_t now = mcp_now();
  if (now < 0)
    return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "read continuation clock");
  if (now >= r->deadline) {
    mcp_finish(r, MCP_TIMEOUT, NULL);
    return mcp_fail(e, MCP_TIMEOUT, 0, "continuation deadline elapsed");
  }
  json *responses = NULL;
  mcp_status s =
      mcp_parse(text ? text : "{}", text ? strlen(text) : 2, &responses, e);
  if (s != MCP_OK)
    return s;
  if (!json_object_is_type(responses, json_type_object)) {
    json_object_put(responses);
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "inputResponses must be an object");
  }
  json *inputs = mcp_field(r->input_result, "inputRequests");
  if (inputs) {
    json_object_object_foreach(inputs, key, value) {
      (void)value;
      json *v = NULL;
      if (!json_object_object_get_ex(responses, key, &v)) {
        json_object_put(responses);
        return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                        "inputResponses is missing a requested input");
      }
    }
  }
  json *state = mcp_field(r->input_result, "requestState");
  json_object_object_del(r->params, "requestState");
  json_object_object_del(r->params, "inputResponses");
  bool ok = mcp_add(r->params, "inputResponses", responses);
  if (ok && state)
    ok = mcp_add(r->params, "requestState", json_object_get(state));
  if (!ok)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "build continuation parameters");
  if (r->client->next_id == INT64_MAX)
    return mcp_fail(e, MCP_INVALID_STATE, 0, "request id exhausted");
  mcp_http_remove(r);
  mcp_buffer_free(&r->body);
  mcp_buffer_free(&r->sse_line);
  mcp_buffer_free(&r->sse_data);
  r->id = ++r->client->next_id;
  r->status = MCP_PENDING;
  r->has_progress = false;
  r->sse_first = true;
  r->sse_skip_lf = false;
  r->sse = false;
  r->json_content_type = false;
  r->http_done = false;
  r->http_status = 0;
  r->transport_code = 0;
  mcp_buffer_free(&r->auth_challenge);
  r->receive_error = MCP_OK;
  r->receive_detail = (mcp_error){0};
  mcp_response_free(&r->validation);
  mcp_response_free(&r->response);
  s = start(r, e);
  if (s != MCP_OK)
    mcp_finish(r, s, e);
  return s;
}
mcp_status mcp_request_destroy(mcp_request *r, mcp_error *e) {
  if (!r)
    return mcp_fail(e, MCP_OK, 0, "success");
  if (r->client->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "cannot destroy a request in a callback");
  mcp_status s = MCP_OK;
  if (r->status == MCP_PENDING)
    s = mcp_request_cancel(r, "request released", e);
  mcp_client *c = r->client;
  mcp_request **p = &c->requests;
  while (*p && *p != r)
    p = &(*p)->next;
  if (*p)
    *p = r->next;
  c->request_count--;
  mcp_http_remove(r);
  json_object_put(r->params);
  json_object_put(r->input_result);
  json_object_put(r->progress_token);
  json_object_put(r->filter);
  json_object_put(r->ack_filter);
  mcp_response_free(&r->response);
  mcp_buffer_free(&r->body);
  mcp_buffer_free(&r->sse_line);
  mcp_buffer_free(&r->sse_data);
  free(r->method);
  mcp_schema_destroy(r->output_schema);
  mcp_response_free(&r->validation);
  mcp_buffer_free(&r->auth_challenge);
  free(r);
  return s;
}
mcp_status mcp_client_poll(mcp_client *c, int ms, mcp_error *e) {
  if (!c || ms < 0)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "poll requires a client and nonnegative timeout");
  if (c->broken || c->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "client is disconnected or already polling");
  int64_t now = mcp_now();
  if (now < 0)
    return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "read monotonic clock");
  int wait = ms;
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->status == MCP_PENDING) {
      if (r->deadline <= now) {
        mcp_status s = cancel(r, "request deadline elapsed", MCP_TIMEOUT, e);
        if (s != MCP_OK)
          return s;
      } else if (r->deadline - now < wait)
        wait = (int)(r->deadline - now);
    }
  c->polling = true;
  mcp_status s =
      c->http ? mcp_http_poll(c, wait, e) : mcp_stdio_poll(c, wait, e);
  c->polling = false;
  if (s != MCP_OK) {
    break_client(c, s, e);
    return s;
  }
  now = mcp_now();
  if (now < 0)
    return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "read monotonic clock");
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->status == MCP_PENDING && r->deadline <= now) {
      s = cancel(r, "request deadline elapsed", MCP_TIMEOUT, e);
      if (s != MCP_OK)
        return s;
    }
  if (!c->http && c->tx_head) {
    c->polling = true;
    s = mcp_stdio_poll(c, 0, e);
    c->polling = false;
    if (s != MCP_OK) {
      break_client(c, s, e);
      return s;
    }
  }
  return mcp_fail(e, MCP_OK, 0, "success");
}
static mcp_status wait_request(mcp_request *r, mcp_error *e) {
  while (r->status == MCP_PENDING) {
    mcp_status s = mcp_client_poll(r->client, 1000, e);
    if (s != MCP_OK && r->status == MCP_PENDING) {
      mcp_finish(r, s, e);
      return s;
    }
  }
  return r->status;
}
static mcp_status sync_request(mcp_client *c, const char *m, const char *p,
                               int ms, mcp_response *out, mcp_error *e) {
  if (!out || out->json)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "output response must be empty");
  mcp_request *r = NULL;
  mcp_status s = submit(c, m, p, ms, &r, e, NULL, NULL);
  if (s != MCP_OK)
    return s;
  wait_request(r, e);
  s = mcp_request_take(r, out, e);
  mcp_request_destroy(r, NULL);
  return s;
}
mcp_status mcp_client_request(mcp_client *c, const char *m, const char *p,
                              mcp_response *r, mcp_error *e) {
  if (!c || !c->ready)
    return mcp_fail(e, MCP_INVALID_STATE, 0, "client is not initialized");
  return sync_request(c, m, p, c->timeout_ms, r, e);
}
mcp_status mcp_client_call(mcp_client *c, const char *m, const char *p,
                           mcp_response *out, mcp_error *e) {
  if (!c || !c->ready || !out || out->json)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid call arguments");
  mcp_response_free(&c->handler_error);
  mcp_request *r = NULL;
  mcp_status s = submit(c, m, p, c->timeout_ms, &r, e, NULL, NULL);
  if (s != MCP_OK)
    return s;
  while ((s = wait_request(r, e)) == MCP_INPUT_REQUIRED && c->on_request) {
    json *inputs = mcp_field(r->input_result, "inputRequests"),
         *responses = json_object_new_object();
    if (!responses) {
      s = mcp_fail(e, MCP_NO_MEMORY, 0, "allocate input responses");
      break;
    }
    s = MCP_OK;
    if (inputs) {
      json_object_object_foreach(inputs, key, input) {
        json *result = NULL;
        bool remote = false;
        s = mcp_invoke(c, json_object_get_string(mcp_field(input, "method")),
                       mcp_field(input, "params"), &result, &remote, e);
        if (s != MCP_OK || remote) {
          json_object_put(result);
          if (remote)
            s = mcp_fail(e, MCP_REMOTE_ERROR, 0,
                         "client input handler declined continuation");
          break;
        }
        if (!mcp_add(responses, key, result)) {
          s = mcp_fail(e, MCP_NO_MEMORY, 0, "append input response");
          break;
        }
      }
    }
    if (s == MCP_OK) {
      const char *text =
          json_object_to_json_string_ext(responses, JSON_C_TO_STRING_PLAIN);
      s = text ? mcp_request_resume(r, text, e)
               : mcp_fail(e, MCP_NO_MEMORY, 0, "serialize input responses");
    }
    json_object_put(responses);
    if (s != MCP_OK)
      break;
    if (mcp_now() >= r->deadline) {
      s = mcp_fail(e, MCP_TIMEOUT, 0, "multi-round-trip deadline elapsed");
      break;
    }
  }
  if (s != r->status) {
    mcp_response raw = {0};
    mcp_request_take(r, &raw, NULL);
    *out = raw;
  } else
    s = mcp_request_take(r, out, e);
  if (c->handler_error.json) {
    mcp_response_free(out);
    *out = c->handler_error;
    c->handler_error = (mcp_response){0};
    json *host = NULL;
    if (mcp_parse(out->json, out->length, &host, NULL) == MCP_OK)
      out->error_code = json_object_get_int64(mcp_field(host, "code"));
    json_object_put(host);
  }
  mcp_request_destroy(r, NULL);
  return s;
}

static mcp_status negotiate(mcp_client *c, const mcp_options *o,
                            mcp_response *r, mcp_error *e) {
  mcp_status s = MCP_OK;
  if (o->protocol != MCP_PROTOCOL_LEGACY) {
    c->modern = true;
    c->protocol = MCP_PROTOCOL_VERSION;
    s = sync_request(c, "server/discover", "{}", o->probe_timeout_ms, r, e);
    if (s == MCP_OK) {
      json *wire = NULL;
      s = mcp_parse(r->json, r->length, &wire, e);
      if (s != MCP_OK)
        return s;
      json *result = mcp_field(wire, "result"),
           *versions = mcp_field(result, "supportedVersions");
      bool match = false;
      if (json_object_is_type(versions, json_type_array))
        for (size_t i = 0; i < json_object_array_length(versions); i++)
          if (mcp_string_is(json_object_array_get_idx(versions, i),
                            MCP_PROTOCOL_VERSION))
            match = true;
      if (!match)
        s = mcp_fail(e, MCP_UNSUPPORTED, 0,
                     "discovery offers no supported protocol version");
      else if (!json_object_is_type(mcp_field(result, "capabilities"),
                                    json_type_object))
        s = mcp_fail(e, MCP_PROTOCOL_ERROR, 0, "discovery lacks capabilities");
      else {
        json_object_put(c->capabilities);
        c->capabilities = json_object_get(mcp_field(result, "capabilities"));
      }
      json_object_put(wire);
      return s;
    }
    if (c->http || o->protocol == MCP_PROTOCOL_MODERN ||
        (s != MCP_TIMEOUT && s != MCP_REMOTE_ERROR) ||
        (s == MCP_REMOTE_ERROR &&
         (r->error_code == -32020 || r->error_code == -32021 ||
          r->error_code == -32022)))
      return s;
    if (r->json && c->on_message)
      c->on_message(c->context, r->json, r->length);
    mcp_response_free(r);
  }
  c->modern = false;
  c->protocol = NULL;
  json *p = json_object_new_object();
  bool ok =
      mcp_add(p, "protocolVersion", json_object_new_string("2025-11-25")) &&
      mcp_add(p, "capabilities", json_object_get(c->client_capabilities)) &&
      mcp_add(p, "clientInfo", mcp_identity(c));
  if (!ok) {
    json_object_put(p);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "build initialize parameters");
  }
  const char *text = json_object_to_json_string_ext(p, JSON_C_TO_STRING_PLAIN);
  s = text ? sync_request(c, "initialize", text, c->timeout_ms, r, e)
           : mcp_fail(e, MCP_NO_MEMORY, 0, "serialize initialize parameters");
  json_object_put(p);
  if (s != MCP_OK)
    return s;
  json *wire = NULL;
  s = mcp_parse(r->json, r->length, &wire, e);
  if (s != MCP_OK)
    return s;
  json *result = mcp_field(wire, "result"),
       *version = mcp_field(result, "protocolVersion");
  const char *versions[] = {"2025-11-25", "2025-06-18", "2025-03-26",
                            "2024-11-05"};
  for (size_t i = 0; i < 4; i++)
    if (mcp_string_is(version, versions[i]))
      c->protocol = versions[i];
  if (!c->protocol)
    s = mcp_fail(e, MCP_UNSUPPORTED, 0,
                 "initialize selected an unsupported version");
  else if (!json_object_is_type(mcp_field(result, "capabilities"),
                                json_type_object) ||
           !json_object_is_type(mcp_field(result, "serverInfo"),
                                json_type_object))
    s = mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                 "initialize lacks capabilities or serverInfo");
  else
    c->capabilities = json_object_get(mcp_field(result, "capabilities"));
  json_object_put(wire);
  if (s != MCP_OK)
    return s;
  json *note = json_object_new_object();
  ok = mcp_add(note, "jsonrpc", json_object_new_string("2.0")) &&
       mcp_add(note, "method",
               json_object_new_string("notifications/initialized"));
  s = ok ? mcp_queue(c, note, 0, e)
         : mcp_fail(e, MCP_NO_MEMORY, 0, "build initialized notification");
  json_object_put(note);
  if (s == MCP_OK)
    s = mcp_client_poll(c, 0, e);
  return s;
}
static mcp_status open_client(const mcp_options *o, const mcp_features *f,
                              const char *url, const char *token, bool lazy,
                              mcp_client **out, mcp_response *r, mcp_error *e) {
  if (out)
    *out = NULL;
  if (!o || !out || !r || r->json || !o->client_name || !o->client_version ||
      o->protocol < MCP_PROTOCOL_AUTO || o->protocol > MCP_PROTOCOL_LEGACY ||
      o->timeout_ms <= 0 || o->probe_timeout_ms <= 0 ||
      o->shutdown_timeout_ms <= 0 || !o->max_message_bytes ||
      o->max_message_bytes >= INT_MAX ||
      (!url && (!o->command || !*o->command || !o->argv || !o->argv[0])) ||
      (url && o->protocol == MCP_PROTOCOL_LEGACY))
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid MCP open options");
  mcp_client *c = calloc(1, sizeof(*c));
  if (!c)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate client");
  c->fd = -1;
  c->pid = -1;
  c->timeout_ms = o->timeout_ms;
  c->shutdown_ms = o->shutdown_timeout_ms;
  c->limit = o->max_message_bytes;
  c->on_message = o->on_message;
  c->context = o->context;
  c->max_pending = f ? f->max_pending : 64;
  c->on_request = f ? f->on_request : NULL;
  c->request_context = f ? f->context : NULL;
  c->name = strdup(o->client_name);
  c->version = strdup(o->client_version);
  c->buffer = malloc(c->limit + 1);
  mcp_status s = MCP_OK;
  if (!c->name || !c->version || !c->buffer) {
    s = mcp_fail(e, MCP_NO_MEMORY, 0, "allocate client buffers");
    goto failed;
  }
  const char *caps = f && f->capabilities_json ? f->capabilities_json : "{}";
  s = mcp_parse(caps, strlen(caps), &c->client_capabilities, e);
  if (s != MCP_OK)
    goto failed;
  if (!json_object_is_type(c->client_capabilities, json_type_object) ||
      !c->max_pending ||
      (!c->on_request && (mcp_field(c->client_capabilities, "roots") ||
                          mcp_field(c->client_capabilities, "sampling") ||
                          mcp_field(c->client_capabilities, "elicitation")))) {
    s = mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                 "client features require capabilities, matching handlers and "
                 "a positive request limit");
    goto failed;
  }
  s = url ? mcp_http_init(c, url, token, e) : mcp_stdio_open(c, o, e);
  if (s != MCP_OK)
    goto failed;
  if (lazy) {
    c->modern = true;
    c->protocol = MCP_PROTOCOL_VERSION;
  } else
    s = negotiate(c, o, r, e);
  if (s == MCP_OK) {
    c->ready = true;
    *out = c;
    return mcp_fail(e, MCP_OK, 0, "success");
  }
failed:
  {
    mcp_error cleanup = {0};
    if (mcp_client_close(c, &cleanup) != MCP_OK && e) {
      e->cleanup_code = cleanup.code;
      e->cleanup_errno = cleanup.system_errno;
      e->cleanup_child_status = cleanup.child_status;
      e->cleanup_message = cleanup.message;
    }
  }
  return s;
}
mcp_status mcp_client_open(const mcp_options *o, mcp_client **c,
                           mcp_response *r, mcp_error *e) {
  return open_client(o, NULL, NULL, NULL, false, c, r, e);
}
mcp_status mcp_client_open_ex(const mcp_options *o, const mcp_features *f,
                              mcp_client **c, mcp_response *r, mcp_error *e) {
  return open_client(o, f, NULL, NULL, false, c, r, e);
}
mcp_status mcp_client_open_http(const mcp_options *o, const mcp_features *f,
                                const char *u, const char *t, mcp_client **c,
                                mcp_response *r, mcp_error *e) {
  if (!u)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "HTTP URL is required");
  return open_client(o, f, u, t, false, c, r, e);
}
mcp_status mcp_client_create_http(const mcp_options *o, const mcp_features *f,
                                  const char *url, const char *token,
                                  mcp_client **out, mcp_error *e) {
  if (!url) {
    if (out)
      *out = NULL;
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "HTTP URL is required");
  }
  mcp_response unused = {0};
  return open_client(o, f, url, token, true, out, &unused, e);
}
const char *mcp_client_protocol_version(const mcp_client *c) {
  return c ? c->protocol : NULL;
}
const char *mcp_client_auth_challenge(const mcp_client *c) {
  return c ? c->auth_challenge : NULL;
}
long mcp_client_http_status(const mcp_client *c) {
  return c ? c->http_status : 0;
}
int mcp_client_transport_code(const mcp_client *c) {
  return c ? c->transport_code : 0;
}

static mcp_status helper(mcp_client *c, const char *cap, const char *method,
                         const char *key, const char *value, const char *args,
                         mcp_response *r, mcp_error *e) {
  if (!c || !r || r->json || (key && !value))
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid helper arguments");
  if (!json_object_is_type(mcp_field(c->capabilities, cap), json_type_object))
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "server did not advertise the requested capability");
  json *p = json_object_new_object();
  if (!p)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate helper parameters");
  bool ok = !key || mcp_add(p, key, json_object_new_string(value));
  if (args) {
    json *a = NULL;
    mcp_status s = mcp_parse(args, strlen(args), &a, e);
    if (s != MCP_OK) {
      json_object_put(p);
      return s;
    }
    if (!json_object_is_type(a, json_type_object)) {
      json_object_put(a);
      json_object_put(p);
      return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                      "arguments must be an object");
    }
    ok = mcp_add(p, "arguments", a) && ok;
  }
  const char *text =
      ok ? json_object_to_json_string_ext(p, JSON_C_TO_STRING_PLAIN) : NULL;
  mcp_status s =
      text ? mcp_client_request(c, method, text, r, e)
           : mcp_fail(e, MCP_NO_MEMORY, 0, "serialize helper parameters");
  json_object_put(p);
  return s;
}
mcp_status mcp_tools_list(mcp_client *c, const char *v, mcp_response *r,
                          mcp_error *e) {
  return helper(c, "tools", "tools/list", v ? "cursor" : NULL, v, NULL, r, e);
}
mcp_status mcp_tools_call(mcp_client *c, const char *v, const char *a,
                          mcp_response *r, mcp_error *e) {
  return helper(c, "tools", "tools/call", "name", v, a ? a : "{}", r, e);
}
mcp_status mcp_resources_list(mcp_client *c, const char *v, mcp_response *r,
                              mcp_error *e) {
  return helper(c, "resources", "resources/list", v ? "cursor" : NULL, v, NULL,
                r, e);
}
mcp_status mcp_resources_read(mcp_client *c, const char *v, mcp_response *r,
                              mcp_error *e) {
  return helper(c, "resources", "resources/read", "uri", v, NULL, r, e);
}
mcp_status mcp_prompts_list(mcp_client *c, const char *v, mcp_response *r,
                            mcp_error *e) {
  return helper(c, "prompts", "prompts/list", v ? "cursor" : NULL, v, NULL, r,
                e);
}
mcp_status mcp_prompts_get(mcp_client *c, const char *v, const char *a,
                           mcp_response *r, mcp_error *e) {
  return helper(c, "prompts", "prompts/get", "name", v, a ? a : "{}", r, e);
}
mcp_status mcp_resource_templates_list(mcp_client *c, const char *v,
                                       mcp_response *r, mcp_error *e) {
  return helper(c, "resources", "resources/templates/list", v ? "cursor" : NULL,
                v, NULL, r, e);
}
mcp_status mcp_completion_complete(mcp_client *c, const char *p,
                                   mcp_response *r, mcp_error *e) {
  if (!c || !json_object_is_type(mcp_field(c->capabilities, "completions"),
                                 json_type_object))
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "server does not advertise completions");
  return mcp_client_request(c, "completion/complete", p, r, e);
}
mcp_status mcp_subscriptions_listen(mcp_client *c, const char *text,
                                    mcp_request **r, mcp_error *e) {
  if (!c)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "client required");
  json *f = NULL;
  mcp_status s = mcp_parse(text ? text : "{}", text ? strlen(text) : 2, &f, e);
  if (s != MCP_OK)
    return s;
  json *p = json_object_new_object();
  bool ok = mcp_add(p, "notifications", f);
  const char *wire =
      ok ? json_object_to_json_string_ext(p, JSON_C_TO_STRING_PLAIN) : NULL;
  s = wire ? mcp_client_submit(c, "subscriptions/listen", wire, c->timeout_ms,
                               r, e)
           : mcp_fail(e, MCP_NO_MEMORY, 0, "build subscription filter");
  json_object_put(p);
  return s;
}
mcp_status mcp_resources_subscribe(mcp_client *c, const char *v,
                                   mcp_response *r, mcp_error *e) {
  if (!c || c->modern)
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "modern peers use subscriptions/listen");
  return helper(c, "resources", "resources/subscribe", "uri", v, NULL, r, e);
}
mcp_status mcp_resources_unsubscribe(mcp_client *c, const char *v,
                                     mcp_response *r, mcp_error *e) {
  if (!c || c->modern)
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "modern peers use subscriptions/listen");
  return helper(c, "resources", "resources/unsubscribe", "uri", v, NULL, r, e);
}
mcp_status mcp_logging_set_level(mcp_client *c, const char *v, mcp_response *r,
                                 mcp_error *e) {
  if (!c || c->modern)
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "modern peers set logLevel in request _meta");
  return helper(c, "logging", "logging/setLevel", "level", v, NULL, r, e);
}

mcp_status mcp_client_close(mcp_client *c, mcp_error *e) {
  if (!c)
    return mcp_fail(e, MCP_OK, 0, "success");
  if (c->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "cannot close client from callback");
  mcp_status s = MCP_OK;
  mcp_error first = {0};
  while (c->requests) {
    mcp_error detail = {0};
    mcp_status q = mcp_request_destroy(c->requests, &detail);
    if (q != MCP_OK && s == MCP_OK) {
      s = q;
      first = detail;
    }
  }
  if (c->http)
    mcp_http_close(c);
  else {
    mcp_error detail = {0};
    mcp_status q = mcp_stdio_close(c, &detail);
    if (q != MCP_OK && s == MCP_OK) {
      s = q;
      first = detail;
    }
  }
  while (c->tx_head) {
    mcp_frame *q = c->tx_head;
    c->tx_head = q->next;
    free(q->wire);
    free(q);
  }
  mcp_response_free(&c->handler_error);
  json_object_put(c->capabilities);
  json_object_put(c->client_capabilities);
  json_object_put(c->tools);
  free(c->buffer);
  free(c->name);
  free(c->version);
  free(c->url);
  free(c->bearer);
  free(c->auth_challenge);
  free(c);
  if (s != MCP_OK) {
    if (e)
      *e = first;
    return s;
  }
  return mcp_fail(e, MCP_OK, 0, "success");
}

mcp_status mcp_tool_call(mcp_client *c, const mcp_tool *tool, const char *args,
                         mcp_response *out, mcp_response *report, mcp_error *e) {
  if (!c || !out || out->json || !report || report == out || report->json)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "tool call needs empty response and report");
  mcp_request *r = NULL;
  mcp_status s = mcp_tool_submit(c, tool, args, c->timeout_ms, &r, e);
  if (s) return s;
  wait_request(r, e);
  s = mcp_request_take(r, out, e);
  *report = r->validation; r->validation = (mcp_response){0};
  mcp_request_destroy(r, NULL);
  return s;
}
