/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static mcp_status retain(mcp_response *r, const char *s, size_t n,
                         mcp_error *e) {
  char *p = malloc(n + 1);
  if (!p)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "retain received frame");
  memcpy(p, s, n);
  p[n] = 0;
  mcp_response_free(r);
  r->json = p;
  r->length = n;
  return MCP_OK;
}
mcp_status mcp_retain_failure(mcp_client *c, mcp_request *origin,
                              const char *text, size_t n, mcp_error *e) {
  if (origin)
    return origin->response.json ? MCP_OK
                                 : retain(&origin->response, text, n, e);
  for (mcp_request *r = c->requests; r; r = r->next) {
    if (r->status == MCP_PENDING && !r->response.json) {
      mcp_status s = retain(&r->response, text, n, e);
      if (s != MCP_OK)
        return s;
    }
  }
  return MCP_OK;
}
static bool capability(mcp_client *c, const char *method, json *p) {
  if (!strcmp(method, "roots/list"))
    return json_object_is_type(mcp_field(c->client_capabilities, "roots"),
                               json_type_object);
  if (!strcmp(method, "sampling/createMessage")) {
    json *cap = mcp_field(c->client_capabilities, "sampling");
    return json_object_is_type(cap, json_type_object) &&
           (!mcp_field(p, "tools") ||
            json_object_is_type(mcp_field(cap, "tools"), json_type_object));
  }
  if (!strcmp(method, "elicitation/create")) {
    json *cap = mcp_field(c->client_capabilities, "elicitation");
    if (mcp_has(p, "mode") && !mcp_string_is(mcp_field(p, "mode"), "url") &&
        !mcp_string_is(mcp_field(p, "mode"), "form"))
      return false;
    if (!c->modern && !mcp_field(p, "mode"))
      return json_object_is_type(cap, json_type_object);
    return json_object_is_type(cap, json_type_object) &&
           json_object_is_type(
               mcp_field(cap, mcp_string_is(mcp_field(p, "mode"), "url")
                                  ? "url"
                                  : "form"),
               json_type_object);
  }
  return false;
}
mcp_status mcp_invoke(mcp_client *c, const char *method, json *p, json **out,
                      bool *is_error, mcp_error *e) {
  *out = NULL;
  *is_error = false;
  if (!c->on_request || !capability(c, method, p))
    return mcp_fail(e, MCP_UNSUPPORTED, 0,
                    "server requested an undeclared client capability");
  const char *text =
      p ? json_object_to_json_string_ext(p, JSON_C_TO_STRING_PLAIN) : "{}";
  if (!text)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "serialize client feature parameters");
  mcp_response result = {0};
  mcp_error detail = {0};
  bool was_polling = c->polling;
  c->polling = true;
  mcp_status s =
      c->on_request(c->request_context, method, text, &result, &detail);
  c->polling = was_polling;
  if (s != MCP_OK && s != MCP_REMOTE_ERROR) {
    mcp_response_free(&c->handler_error);
    c->handler_error = result;
    detail.code = s;
    if (!detail.message)
      detail.message = mcp_status_string(s);
    if (e)
      *e = detail;
    return s;
  }
  if (!result.json)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "client handler returned no result");
  mcp_status parsed = mcp_parse(result.json, result.length, out, e);
  mcp_response_free(&c->handler_error);
  c->handler_error = result;
  if (parsed != MCP_OK)
    return parsed;
  if (!json_object_is_type(*out, json_type_object)) {
    json_object_put(*out);
    *out = NULL;
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "client handler result must be an object");
  }
  if (s == MCP_REMOTE_ERROR &&
      (!json_object_is_type(mcp_field(*out, "code"), json_type_int) ||
       !json_object_is_type(mcp_field(*out, "message"), json_type_string))) {
    json_object_put(*out);
    *out = NULL;
    return mcp_fail(
        e, MCP_INVALID_ARGUMENT, 0,
        "client handler error needs integer code and string message");
  }
  *is_error = s == MCP_REMOTE_ERROR;
  if (!*is_error)
    mcp_response_free(&c->handler_error);
  return MCP_OK;
}
static mcp_status legacy_reply(mcp_client *c, json *id, json *method, json *p,
                               mcp_error *e) {
  json *body = NULL;
  bool error = false;
  mcp_status s = MCP_OK;
  if (mcp_string_is(method, "ping"))
    body = json_object_new_object();
  else
    s = mcp_invoke(c, json_object_get_string(method), p, &body, &error, e);
  mcp_response_free(&c->handler_error);
  if (s != MCP_OK) {
    body = json_object_new_object();
    error = true;
    if (!mcp_add(body, "code",
                 json_object_new_int(s == MCP_UNSUPPORTED ? -32601 : -32603)) ||
        !mcp_add(body, "message",
                 json_object_new_string(
                     e && e->message ? e->message : mcp_status_string(s)))) {
      json_object_put(body);
      return mcp_fail(e, MCP_NO_MEMORY, 0, "build client capability error");
    }
  }
  json *reply = json_object_new_object();
  bool ok = mcp_add(reply, "jsonrpc", json_object_new_string("2.0")) &&
            mcp_add(reply, "id", json_object_get(id));
  if (!ok) {
    json_object_put(body);
    json_object_put(reply);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "build server reply envelope");
  }
  ok = mcp_add(reply, error ? "error" : "result", body);
  s = ok ? mcp_queue(c, reply, 0, e)
         : mcp_fail(e, MCP_NO_MEMORY, 0, "build server reply body");
  json_object_put(reply);
  return s;
}
bool mcp_filter_valid(json *f) {
  if (!json_object_is_type(f, json_type_object))
    return false;
  const char *flags[] = {"toolsListChanged", "promptsListChanged",
                         "resourcesListChanged"};
  for (size_t i = 0; i < 3; i++) {
    json *v = mcp_field(f, flags[i]);
    if (mcp_has(f, flags[i]) && !json_object_is_type(v, json_type_boolean))
      return false;
  }
  json *a = mcp_field(f, "resourceSubscriptions");
  if (mcp_has(f, "resourceSubscriptions")) {
    if (!json_object_is_type(a, json_type_array))
      return false;
    for (size_t i = 0; i < json_object_array_length(a); i++)
      if (!json_object_is_type(json_object_array_get_idx(a, i),
                               json_type_string))
        return false;
  }
  return true;
}
static bool array_has(json *a, json *v) {
  if (!json_object_is_type(a, json_type_array))
    return false;
  for (size_t i = 0; i < json_object_array_length(a); i++)
    if (json_object_equal(json_object_array_get_idx(a, i), v))
      return true;
  return false;
}
static bool subset(json *a, json *b) {
  const char *flags[] = {"toolsListChanged", "promptsListChanged",
                         "resourcesListChanged"};
  for (size_t i = 0; i < 3; i++)
    if (json_object_get_boolean(mcp_field(a, flags[i])) &&
        !json_object_get_boolean(mcp_field(b, flags[i])))
      return false;
  json *uris = mcp_field(a, "resourceSubscriptions");
  if (uris)
    for (size_t i = 0; i < json_object_array_length(uris); i++)
      if (!array_has(mcp_field(b, "resourceSubscriptions"),
                     json_object_array_get_idx(uris, i)))
        return false;
  return true;
}
static mcp_status notification(mcp_client *c, mcp_request *origin, json *o,
                               mcp_error *e) {
  json *p = mcp_field(o, "params");
  const char *m = json_object_get_string(mcp_field(o, "method"));
  if (!strcmp(m, "notifications/cancelled")) {
    json *id = mcp_field(p, "requestId");
    mcp_request *r = json_object_is_type(id, json_type_int)
                         ? mcp_find(c, json_object_get_int64(id))
                         : NULL;
    /* The specification explicitly ignores invalid or raced cancellation. */
    if (r && r->status == MCP_PENDING && (!c->modern || r->subscription))
      mcp_finish(r, MCP_CANCELLED, NULL);
    return MCP_OK;
  }
  if (!strcmp(m, "notifications/progress")) {
    json *token = mcp_field(p, "progressToken"),
         *progress = mcp_field(p, "progress"), *total = mcp_field(p, "total");
    mcp_request *r = NULL;
    for (mcp_request *q = c->requests; q; q = q->next)
      if (q->status == MCP_PENDING && q->progress_token && token &&
          json_object_get_type(token) ==
              json_object_get_type(q->progress_token) &&
          json_object_equal(q->progress_token, token)) {
        r = q;
        break;
      }
    if (!r || (origin && r != origin) ||
        (!json_object_is_type(progress, json_type_int) &&
         !json_object_is_type(progress, json_type_double)))
      return mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                      "progress has no active token or numeric value");
    double v = json_object_get_double(progress);
    if (!isfinite(v) || v < 0 || (r->has_progress && v <= r->progress))
      return mcp_fail(e, MCP_PROTOCOL_ERROR, 0, "progress did not increase");
    if (total && ((!json_object_is_type(total, json_type_int) &&
                   !json_object_is_type(total, json_type_double)) ||
                  !isfinite(json_object_get_double(total)) ||
                  json_object_get_double(total) < 0))
      return mcp_fail(e, MCP_PROTOCOL_ERROR, 0, "invalid progress total");
    r->progress = v;
    r->has_progress = true;
    return MCP_OK;
  }
  const char *filter =
      !strcmp(m, "notifications/tools/list_changed")     ? "toolsListChanged"
      : !strcmp(m, "notifications/prompts/list_changed") ? "promptsListChanged"
      : !strcmp(m, "notifications/resources/list_changed")
          ? "resourcesListChanged"
          : NULL;
  bool ack = !strcmp(m, "notifications/subscriptions/acknowledged"),
       updated = !strcmp(m, "notifications/resources/updated");
  if (c->modern && (ack || filter || updated)) {
    json *sid = mcp_field(mcp_field(p, "_meta"),
                          "io.modelcontextprotocol/subscriptionId");
    mcp_request *r = json_object_is_type(sid, json_type_int)
                         ? mcp_find(c, json_object_get_int64(sid))
                         : NULL;
    if (!r || !r->subscription || r->status != MCP_PENDING ||
        (origin && r != origin))
      return mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                      "notification has no matching subscription");
    if (ack) {
      json *f = mcp_field(p, "notifications");
      if (r->acknowledged || !mcp_filter_valid(f) || !subset(f, r->filter))
        return mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                        "invalid subscription acknowledgment");
      r->ack_filter = json_object_get(f);
      r->acknowledged = true;
      r->deadline = INT64_MAX;
    } else if (!r->acknowledged ||
               (filter &&
                !json_object_get_boolean(mcp_field(r->ack_filter, filter))) ||
               (updated &&
                !array_has(mcp_field(r->ack_filter, "resourceSubscriptions"),
                           mcp_field(p, "uri"))))
      return mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                      "unacknowledged or unrequested subscription event");
  }
  return MCP_OK;
}
mcp_status mcp_dispatch(mcp_client *c, mcp_request *origin, const char *text,
                        size_t n, mcp_error *e) {
  json *o = NULL;
  mcp_status s = mcp_parse(text, n, &o, e);
  if (s != MCP_OK) {
    if (s != MCP_NO_MEMORY &&
        mcp_retain_failure(c, origin, text, n, e) != MCP_OK)
      return MCP_NO_MEMORY;
    return s;
  }
  json *method = mcp_field(o, "method"), *id = mcp_field(o, "id"),
       *result = mcp_field(o, "result"), *error = mcp_field(o, "error"),
       *p = mcp_field(o, "params"), *unused;
  bool object = json_object_is_type(o, json_type_object),
       has_id = object && json_object_object_get_ex(o, "id", &unused),
       has_result = object && json_object_object_get_ex(o, "result", &unused),
       has_error = object && json_object_object_get_ex(o, "error", &unused);
  if (!mcp_string_is(mcp_field(o, "jsonrpc"), "2.0"))
    goto invalid;
  if (mcp_has(o, "method")) {
    if (!json_object_is_type(method, json_type_string) ||
        strlen(json_object_get_string(method)) !=
            (size_t)json_object_get_string_len(method) ||
        has_result || has_error ||
        (mcp_has(o, "params") && !json_object_is_type(p, json_type_object)))
      goto invalid;
    if (has_id) {
      if (c->modern || (!json_object_is_type(id, json_type_int) &&
                        !json_object_is_type(id, json_type_string)))
        goto invalid;
      if (c->on_message)
        c->on_message(c->context, text, n);
      s = legacy_reply(c, id, method, p, e);
    } else {
      s = notification(c, origin, o, e);
      if (s == MCP_OK && c->on_message)
        c->on_message(c->context, text, n);
    }
    if (s != MCP_OK && mcp_retain_failure(c, origin, text, n, e) != MCP_OK)
      s = MCP_NO_MEMORY;
    json_object_put(o);
    return s;
  }
  if (!has_id || !json_object_is_type(id, json_type_int) ||
      has_result == has_error)
    goto invalid;
  int64_t rid = json_object_get_int64(id);
  mcp_request *r = mcp_find(c, rid);
  if ((!r || r->status != MCP_PENDING) && mcp_retired(c, rid)) {
    json_object_put(o);
    return MCP_OK;
  }
  if (!r || r->status != MCP_PENDING || (origin && r != origin))
    goto invalid;
  s = retain(&r->response, text, n, e);
  if (s != MCP_OK) {
    json_object_put(o);
    return s;
  }
  if (has_error) {
    if (!json_object_is_type(error, json_type_object) ||
        !json_object_is_type(mcp_field(error, "code"), json_type_int) ||
        !json_object_is_type(mcp_field(error, "message"), json_type_string))
      goto invalid;
    r->response.error_code = json_object_get_int64(mcp_field(error, "code"));
    mcp_finish(r, MCP_REMOTE_ERROR, NULL);
  } else {
    if (!json_object_is_type(result, json_type_object))
      goto invalid;
    json *type = mcp_field(result, "resultType"),
         *tool_error = mcp_field(result, "isError");
    if (type && !mcp_string_is(type, "complete") &&
        !mcp_string_is(type, "input_required"))
      goto invalid;
    if (mcp_string_is(type, "input_required")) {
      if (strcmp(r->method, "tools/call") &&
          strcmp(r->method, "resources/read") &&
          strcmp(r->method, "prompts/get"))
        goto invalid;
      json *inputs = mcp_field(result, "inputRequests"),
           *state = mcp_field(result, "requestState");
      if ((!inputs && !state) ||
          (mcp_has(result, "inputRequests") &&
           !json_object_is_type(inputs, json_type_object)) ||
          (mcp_has(result, "requestState") &&
           !json_object_is_type(state, json_type_string)))
        goto invalid;
      if (inputs) {
        json_object_object_foreach(inputs, key, input) {
          (void)key;
          json *m = mcp_field(input, "method");
          if (!json_object_is_type(m, json_type_string) ||
              strlen(json_object_get_string(m)) !=
                  (size_t)json_object_get_string_len(m) ||
              (mcp_has(input, "params") &&
               !json_object_is_type(mcp_field(input, "params"),
                                    json_type_object)) ||
              !capability(c, json_object_get_string(m),
                          mcp_field(input, "params")))
            goto invalid;
        }
      }
      json_object_put(r->input_result);
      r->input_result = json_object_get(result);
      mcp_finish(r, MCP_INPUT_REQUIRED, NULL);
    } else {
      if (!strcmp(r->method, "tools/call") && tool_error &&
          !json_object_is_type(tool_error, json_type_boolean))
        goto invalid;
      if (r->subscription) {
        json *sid = mcp_field(mcp_field(result, "_meta"),
                              "io.modelcontextprotocol/subscriptionId");
        if (!json_object_is_type(sid, json_type_int) ||
            json_object_get_int64(sid) != r->id)
          goto invalid;
      }
      if (c->modern && !strcmp(r->method, "server/discover")) {
        json *versions = mcp_field(result, "supportedVersions"),
             *caps = mcp_field(result, "capabilities");
        bool supported = false;
        if (!json_object_is_type(versions, json_type_array) ||
            !json_object_is_type(caps, json_type_object))
          goto invalid;
        for (size_t i = 0; i < json_object_array_length(versions); i++)
          if (mcp_string_is(json_object_array_get_idx(versions, i),
                            MCP_PROTOCOL_VERSION))
            supported = true;
        if (!supported) {
          mcp_finish(r, MCP_UNSUPPORTED, NULL);
          json_object_put(o);
          return MCP_OK;
        }
        json_object_put(c->capabilities);
        c->capabilities = json_object_get(caps);
      }
      if (c->http && !strcmp(r->method, "tools/list")) {
        if (!mcp_field(r->params, "cursor")) {
          json_object_put(c->tools);
          c->tools = NULL;
        }
        s = mcp_http_cache_tools(c, result, e);
        if (s != MCP_OK) {
          json_object_put(o);
          return s;
        }
      }
      if (!strcmp(r->method, "tools/call")) {
        s = mcp_schema_result(r, result, e);
        if (s != MCP_OK) {
          mcp_finish(r, s, e);
          json_object_put(o);
          return MCP_OK; /* Semantic failure belongs only to this request. */
        }
      }
      mcp_finish(r,
                 !strcmp(r->method, "tools/call") &&
                         json_object_get_boolean(tool_error)
                     ? MCP_TOOL_ERROR
                     : MCP_OK,
                 NULL);
    }
  }
  json_object_put(o);
  return MCP_OK;
invalid:
  s = mcp_retain_failure(c, origin, text, n, e);
  json_object_put(o);
  if (s != MCP_OK)
    return s;
  return mcp_fail(e, MCP_PROTOCOL_ERROR, 0,
                  "invalid MCP envelope, result, correlation or capability");
}
