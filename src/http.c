/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static bool safe_value(const char *s) {
  if (!s || !*s)
    return true;
  size_t n = strlen(s);
  if (isspace((unsigned char)s[0]) || isspace((unsigned char)s[n - 1]))
    return false;
  if (n >= 11 && !strncmp(s, "=?base64?", 9) && !strcmp(s + n - 2, "?="))
    return false;
  for (; *s; s++)
    if ((unsigned char)*s < 32 || (unsigned char)*s > 126)
      return false;
  return true;
}
static bool token(const char *s) {
  if (!s || !*s)
    return false;
  for (; *s; s++)
    if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
          (*s >= '0' && *s <= '9')) &&
        !strchr("!#$%&'*+-.^_`|~", *s))
      return false;
  return true;
}
static char *encoded(const char *s, size_t n) {
  static const char b64[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  char *p = malloc(9 + 4 * ((n + 2) / 3) + 2 + 1);
  if (!p)
    return NULL;
  memcpy(p, "=?base64?", 9);
  size_t k = 9;
  for (size_t i = 0; i < n; i += 3) {
    unsigned a = (unsigned char)s[i],
             b = i + 1 < n ? (unsigned char)s[i + 1] : 0,
             c = i + 2 < n ? (unsigned char)s[i + 2] : 0;
    p[k++] = b64[a >> 2];
    p[k++] = b64[((a & 3) << 4) | (b >> 4)];
    p[k++] = i + 1 < n ? b64[((b & 15) << 2) | (c >> 6)] : '=';
    p[k++] = i + 2 < n ? b64[c & 63] : '=';
  }
  p[k++] = '?';
  p[k++] = '=';
  p[k] = 0;
  return p;
}
static mcp_status header(mcp_request *r, const char *name, const char *value,
                         size_t n, mcp_error *e) {
  char *enc = NULL;
  if (!safe_value(value) || strlen(value) != n) {
    enc = encoded(value, n);
    if (!enc)
      return mcp_fail(e, MCP_NO_MEMORY, 0, "encode MCP header");
    value = enc;
    n = strlen(enc);
  }
  size_t z = strlen(name);
  char *line = malloc(z + n + 3);
  if (!line) {
    free(enc);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate HTTP header");
  }
  memcpy(line, name, z);
  line[z] = ':';
  line[z + 1] = ' ';
  memcpy(line + z + 2, value, n);
  line[z + n + 2] = 0;
  /* libcurl uses a semicolon to send an explicitly empty header value. */
  if (!n) {
    line[z] = ';';
    line[z + 1] = 0;
  }
  struct curl_slist *h = curl_slist_append(r->headers, line);
  free(line);
  free(enc);
  if (!h)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "append HTTP header");
  r->headers = h;
  return MCP_OK;
}
/* Walk only explicit properties. Never resolve refs, items or compositions. */
static mcp_status schema_headers(json *schema, json *names, bool path,
                                 bool property) {
  if (!json_object_is_type(schema, json_type_object))
    return MCP_OK;
  json *annotation = NULL;
  if (json_object_object_get_ex(schema, "x-mcp-header", &annotation)) {
    json *type = mcp_field(schema, "type");
    if (!path || !property ||
        !json_object_is_type(annotation, json_type_string) ||
        strlen(json_object_get_string(annotation)) !=
            (size_t)json_object_get_string_len(annotation) ||
        !token(json_object_get_string(annotation)) ||
        (!mcp_string_is(type, "string") && !mcp_string_is(type, "integer") &&
         !mcp_string_is(type, "boolean")))
      return MCP_INVALID_ARGUMENT;
    const char *n = json_object_get_string(annotation);
    json_object_object_foreach(names, key, value) {
      (void)value;
      if (!strcasecmp(n, key))
        return MCP_INVALID_ARGUMENT;
    }
    if (!mcp_add(names, n, json_object_new_boolean(true)))
      return MCP_NO_MEMORY;
  }
  const char *maps[] = {"properties",  "patternProperties", "$defs",
                        "definitions", "dependentSchemas",  "dependencies"};
  for (size_t i = 0; i < sizeof(maps) / sizeof(*maps); i++) {
    json *map = mcp_field(schema, maps[i]);
    if (json_object_is_type(map, json_type_object)) {
      json_object_object_foreach(map, key, child) {
        (void)key;
        mcp_status s = schema_headers(child, names, path && i == 0, true);
        if (s != MCP_OK)
          return s;
      }
    }
  }
  const char *single[] = {"additionalProperties",
                          "unevaluatedProperties",
                          "propertyNames",
                          "contains",
                          "items",
                          "additionalItems",
                          "unevaluatedItems",
                          "not",
                          "if",
                          "then",
                          "else"};
  for (size_t i = 0; i < sizeof(single) / sizeof(*single); i++) {
    mcp_status s =
        schema_headers(mcp_field(schema, single[i]), names, false, false);
    if (s != MCP_OK)
      return s;
  }
  const char *arrays[] = {"allOf", "anyOf", "oneOf", "prefixItems"};
  for (size_t i = 0; i < sizeof(arrays) / sizeof(*arrays); i++) {
    json *a = mcp_field(schema, arrays[i]);
    if (json_object_is_type(a, json_type_array))
      for (size_t j = 0; j < json_object_array_length(a); j++) {
        mcp_status s = schema_headers(json_object_array_get_idx(a, j), names,
                                      false, false);
        if (s != MCP_OK)
          return s;
      }
  }
  return MCP_OK;
}
mcp_status mcp_http_cache_tools(mcp_client *c, json *result, mcp_error *e) {
  json *a = mcp_field(result, "tools");
  if (!json_object_is_type(a, json_type_array))
    return mcp_fail(e, MCP_PROTOCOL_ERROR, 0, "tools/list needs an array");
  if (!c->tools)
    c->tools = json_object_new_array();
  if (!c->tools)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate tool catalog");
  for (size_t i = 0; i < json_object_array_length(a); i++) {
    json *tool = json_object_array_get_idx(a, i),
         *names = json_object_new_object();
    if (!names)
      return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate tool header index");
    mcp_status valid =
        schema_headers(mcp_field(tool, "inputSchema"), names, true, false);
    json_object_put(names);
    if (valid == MCP_NO_MEMORY)
      return mcp_fail(e, valid, 0, "index tool header annotations");
    if (valid == MCP_OK &&
        json_object_array_add(c->tools, json_object_get(tool)) != 0)
      return mcp_fail(e, MCP_NO_MEMORY, 0, "retain tool catalog");
  }
  return MCP_OK;
}
mcp_status mcp_client_tools_catalog(mcp_client *c, mcp_response *out,
                                    mcp_error *e) {
  if (!c || !c->http || !c->tools)
    return mcp_fail(e, MCP_INVALID_STATE, 0, "no HTTP tool catalog available");
  const char *s =
      json_object_to_json_string_ext(c->tools, JSON_C_TO_STRING_PLAIN);
  return s ? mcp_response_set(out, s, e)
           : mcp_fail(e, MCP_NO_MEMORY, 0, "serialize tool catalog");
}
static mcp_status mirror(mcp_request *r, json *schema, json *value,
                         mcp_error *e) {
  json *name = mcp_field(schema, "x-mcp-header");
  if (name && value) {
    const char *v = NULL;
    size_t n = 0;
    enum json_type t = json_object_get_type(value);
    if (t == json_type_string) {
      v = json_object_get_string(value);
      n = (size_t)json_object_get_string_len(value);
    } else if (t == json_type_boolean ||
               (t == json_type_int &&
                json_object_get_int64(value) >= -9007199254740991LL &&
                json_object_get_int64(value) <= 9007199254740991LL)) {
      v = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
      if (v)
        n = strlen(v);
    }
    if (!v)
      return mcp_fail(
          e, MCP_INVALID_ARGUMENT, 0,
          "mirrored argument must be a safe integer, string or boolean");
    if (v) {
      const char *suffix = json_object_get_string(name);
      size_t len = strlen(suffix);
      char *field = malloc(len + 11);
      if (!field)
        return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate mirrored header name");
      memcpy(field, "Mcp-Param-", 10);
      memcpy(field + 10, suffix, len + 1);
      mcp_status s = header(r, field, v, n, e);
      free(field);
      if (s != MCP_OK)
        return s;
    }
  }
  json *props = mcp_field(schema, "properties");
  if (json_object_is_type(props, json_type_object) &&
      json_object_is_type(value, json_type_object)) {
    json_object_object_foreach(props, key, child) {
      mcp_status s = mirror(r, child, mcp_field(value, key), e);
      if (s != MCP_OK)
        return s;
    }
  }
  return MCP_OK;
}
static mcp_status sse_line(mcp_request *r) {
  mcp_error *e = &r->receive_detail;
  size_t n = r->sse_line.len;
  char *s = r->sse_line.data;
  if (r->sse_first && n >= 3 && !memcmp(s, "\xef\xbb\xbf", 3)) {
    s += 3;
    n -= 3;
  }
  r->sse_first = false;
  mcp_status rc = MCP_OK;
  if (!n) {
    if (r->sse_data.len) {
      if (r->sse_data.data[r->sse_data.len - 1] == '\n')
        r->sse_data.len--;
      if (r->sse_message)
        rc = mcp_dispatch(r->client, r, r->sse_data.data, r->sse_data.len, e);
    }
    r->sse_data.len = 0;
    r->sse_message = true;
  } else if (*s != ':') {
    char *colon = memchr(s, ':', n);
    size_t field = colon ? (size_t)(colon - s) : n;
    const char *v = colon ? colon + 1 : s + n;
    size_t len = n - (size_t)(v - s);
    if (len && *v == ' ') {
      v++;
      len--;
    }
    if (field == 4 && !memcmp(s, "data", 4)) {
      rc = mcp_buffer_append(&r->sse_data, v, len, r->client->limit, e);
      if (rc == MCP_OK)
        rc = mcp_buffer_append(&r->sse_data, "\n", 1, r->client->limit, e);
    } else if (field == 5 && !memcmp(s, "event", 5))
      r->sse_message = !len || (len == 7 && !memcmp(v, "message", 7));
  }
  r->sse_line.len = 0;
  return rc;
}
static size_t receive(char *p, size_t size, size_t count, void *ctx) {
  mcp_request *r = ctx;
  size_t n = size * count;
  mcp_status s = MCP_OK;
  if (!r->sse)
    s = mcp_buffer_append(&r->body, p, n, r->client->limit, &r->receive_detail);
  else
    for (size_t i = 0; i < n && s == MCP_OK; i++) {
      unsigned char ch = (unsigned char)p[i];
      if (r->sse_skip_lf) {
        r->sse_skip_lf = false;
        if (ch == '\n')
          continue;
      }
      if (ch == '\r' || ch == '\n') {
        s = sse_line(r);
        r->sse_skip_lf = ch == '\r';
      } else
        s = mcp_buffer_append(&r->sse_line, (char *)&ch, 1, r->client->limit,
                              &r->receive_detail);
    }
  if (s != MCP_OK) {
    r->receive_error = s;
    return 0;
  }
  return n;
}
static size_t receive_header(char *p, size_t size, size_t count, void *ctx) {
  mcp_request *r = ctx;
  size_t n = size * count;
  /* A 1xx response (or proxy CONNECT) precedes a separate header block. */
  if (n >= 5 && !memcmp(p, "HTTP/", 5)) {
    mcp_buffer_free(&r->auth_challenge);
    r->sse = false;
    r->json_content_type = false;
  }
  if (n > 13 && !strncasecmp(p, "Content-Type:", 13)) {
    const char *v = p + 13;
    while (v < p + n && (*v == ' ' || *v == '\t'))
      v++;
    size_t len = (size_t)(p + n - v);
    r->sse = len >= 17 && !strncasecmp(v, "text/event-stream", 17) &&
             (len == 17 || strchr("; \t\r\n", v[17]));
    r->json_content_type = len >= 16 &&
                           !strncasecmp(v, "application/json", 16) &&
                           (len == 16 || strchr("; \t\r\n", v[16]));
  }
  if (n > 17 && !strncasecmp(p, "WWW-Authenticate:", 17)) {
    const char *v = p + 17, *end = p + n;
    while (v < end && (*v == ' ' || *v == '\t'))
      v++;
    while (end > v && (end[-1] == '\r' || end[-1] == '\n'))
      end--;
    size_t len = (size_t)(end - v);
    size_t used = r->auth_challenge.len;
    size_t separator = r->auth_challenge.data ? 2 : 0;
    if (separator > r->client->limit - used ||
        len > r->client->limit - used - separator) {
      r->receive_error = mcp_fail(&r->receive_detail, MCP_MESSAGE_TOO_LARGE, 0,
                                  "authentication challenge too large");
      return 0;
    }
    mcp_status rc = MCP_OK;
    if (separator)
      rc = mcp_buffer_append(&r->auth_challenge, ", ", separator,
                             r->client->limit, &r->receive_detail);
    if (rc == MCP_OK)
      rc = mcp_buffer_append(&r->auth_challenge, v, len, r->client->limit,
                             &r->receive_detail);
    if (rc != MCP_OK) {
      r->receive_error = rc;
      return 0;
    }
    char *s = malloc(len + 1);
    if (!s) {
      r->receive_error = mcp_fail(&r->receive_detail, MCP_NO_MEMORY, 0,
                                  "copy authentication challenge");
      return 0;
    }
    memcpy(s, v, len);
    s[len] = 0;
    free(r->client->auth_challenge);
    r->client->auth_challenge = s;
  }
  return n;
}
mcp_status mcp_client_set_bearer(mcp_client *c, const char *value,
                                 mcp_error *e) {
  if (!c || !c->http || c->polling)
    return mcp_fail(e, MCP_INVALID_STATE, 0,
                    "bearer token requires an HTTP client outside callbacks");
  if (value)
    for (const char *p = value; *p; p++)
      if ((unsigned char)*p <= 32 || (unsigned char)*p >= 127)
        return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid bearer token");
  char *copy = value ? strdup(value) : NULL;
  if (value && !copy)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "copy bearer token");
  free(c->bearer);
  c->bearer = copy;
  return MCP_OK;
}
mcp_status mcp_http_init(mcp_client *c, const char *url, const char *bearer,
                         mcp_error *e) {
  CURLU *u = curl_url();
  if (!u)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate URL parser");
  CURLUcode code = curl_url_set(u, CURLUPART_URL, url, 0);
  char *scheme = NULL, *host = NULL, *user = NULL, *password = NULL,
       *fragment = NULL;
  if (!code)
    code = curl_url_get(u, CURLUPART_SCHEME, &scheme, 0);
  if (!code)
    code = curl_url_get(u, CURLUPART_HOST, &host, 0);
  bool invalid = code || (!scheme) || (!host);
  if (!invalid) {
    bool tls = !strcmp(scheme, "https"), loop = !strcmp(host, "localhost") ||
                                                !strcmp(host, "127.0.0.1") ||
                                                !strcmp(host, "[::1]");
    invalid = !tls && (strcmp(scheme, "http") || !loop);
  }
  if (curl_url_get(u, CURLUPART_USER, &user, 0) == CURLUE_OK ||
      curl_url_get(u, CURLUPART_PASSWORD, &password, 0) == CURLUE_OK ||
      curl_url_get(u, CURLUPART_FRAGMENT, &fragment, 0) == CURLUE_OK)
    invalid = true;
  curl_free(scheme);
  curl_free(host);
  curl_free(user);
  curl_free(password);
  curl_free(fragment);
  curl_url_cleanup(u);
  if (invalid)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0,
                    "endpoint requires HTTPS or loopback HTTP, without "
                    "credentials or fragment");
  c->http = true;
  c->url = strdup(url);
  c->multi = curl_multi_init();
  if (!c->url || !c->multi)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "initialize HTTP client");
  return mcp_client_set_bearer(c, bearer, e);
}
void mcp_http_remove(mcp_request *r) {
  if (r->easy) {
    long status = 0;
    curl_easy_getinfo(r->easy, CURLINFO_RESPONSE_CODE, &status);
    if (status) {
      r->http_status = status;
      r->client->http_status = status;
    }
    curl_multi_remove_handle(r->client->multi, r->easy);
    curl_easy_cleanup(r->easy);
    r->easy = NULL;
  }
  curl_slist_free_all(r->headers);
  r->headers = NULL;
  free(r->post_body);
  r->post_body = NULL;
}
void mcp_http_close(mcp_client *c) {
  if (c->multi)
    curl_multi_cleanup(c->multi);
  c->multi = NULL;
}

mcp_status mcp_http_submit(mcp_request *r, json *o, mcp_error *e) {
  mcp_client *c = r->client;
  const char *wire = json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN);
  if (!wire)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "serialize HTTP request");
  if (strlen(wire) > c->limit)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0,
                    "outgoing HTTP request exceeds message limit");
  r->post_body = strdup(wire);
  r->easy = curl_easy_init();
  r->sse_message = true;
  if (!r->post_body || !r->easy)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate HTTP request");
  mcp_status s = header(r, "Content-Type", "application/json", 16, e);
  if (s == MCP_OK)
    s = header(r, "Accept", "application/json, text/event-stream", 35, e);
  if (s == MCP_OK)
    s = header(r, "MCP-Protocol-Version", c->protocol, strlen(c->protocol), e);
  if (s == MCP_OK)
    s = header(r, "Mcp-Method", r->method, strlen(r->method), e);
  json *name = NULL;
  if (!strcmp(r->method, "tools/call") || !strcmp(r->method, "prompts/get"))
    name = mcp_field(r->params, "name");
  else if (!strcmp(r->method, "resources/read"))
    name = mcp_field(r->params, "uri");
  if (s == MCP_OK && json_object_is_type(name, json_type_string))
    s = header(r, "Mcp-Name", json_object_get_string(name),
               (size_t)json_object_get_string_len(name), e);
  if (s == MCP_OK && !strcmp(r->method, "tools/call") && c->tools)
    for (size_t i = 0; i < json_object_array_length(c->tools); i++) {
      json *tool = json_object_array_get_idx(c->tools, i);
      if (name && json_object_equal(name, mcp_field(tool, "name"))) {
        s = mirror(r, mcp_field(tool, "inputSchema"),
                   mcp_field(r->params, "arguments"), e);
        break;
      }
    }
  if (s == MCP_OK && c->bearer) {
    size_t n = strlen(c->bearer);
    char *v = malloc(n + 8);
    if (!v)
      s = mcp_fail(e, MCP_NO_MEMORY, 0, "allocate authorization header");
    else {
      memcpy(v, "Bearer ", 7);
      memcpy(v + 7, c->bearer, n + 1);
      s = header(r, "Authorization", v, n + 7, e);
      free(v);
    }
  }
  if (s != MCP_OK)
    return s;
#define SET(option, value)                                                     \
  do {                                                                         \
    CURLcode rc = curl_easy_setopt(r->easy, option, value);                    \
    if (rc != CURLE_OK) {                                                      \
      r->transport_code = rc;                                                  \
      c->transport_code = rc;                                                  \
      return mcp_fail(e, MCP_SYSTEM_ERROR, 0, "configure HTTP transfer");      \
    }                                                                          \
  } while (0)
  SET(CURLOPT_URL, c->url);
  SET(CURLOPT_POST, 1L);
  SET(CURLOPT_POSTFIELDS, r->post_body);
  SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)strlen(r->post_body));
  SET(CURLOPT_HTTPHEADER, r->headers);
  SET(CURLOPT_WRITEFUNCTION, receive);
  SET(CURLOPT_WRITEDATA, r);
  SET(CURLOPT_HEADERFUNCTION, receive_header);
  SET(CURLOPT_HEADERDATA, r);
  SET(CURLOPT_PRIVATE, r);
  SET(CURLOPT_FOLLOWLOCATION, 0L);
  SET(CURLOPT_SSL_VERIFYPEER, 1L);
  SET(CURLOPT_SSL_VERIFYHOST, 2L);
  SET(CURLOPT_NOSIGNAL, 1L);
  SET(CURLOPT_PROTOCOLS_STR, "http,https");
#undef SET
  CURLMcode rc = curl_multi_add_handle(c->multi, r->easy);
  if (rc != CURLM_OK)
    return mcp_fail(e, MCP_SYSTEM_ERROR, 0, "add HTTP transfer");
  r->sent = true;
  return MCP_OK;
}
static mcp_status http_messages(mcp_client *c, mcp_error *e) {
  int left;
  CURLMsg *msg;
  while ((msg = curl_multi_info_read(c->multi, &left))) {
    if (msg->msg != CURLMSG_DONE)
      continue;
    mcp_request *r = NULL;
    curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &r);
    if (!r)
      continue;
    curl_easy_getinfo(r->easy, CURLINFO_RESPONSE_CODE, &r->http_status);
    r->transport_code = msg->data.result;
    c->http_status = r->http_status;
    c->transport_code = r->transport_code;
    r->http_done = true;
    mcp_status s = MCP_OK;
    mcp_error detail = {0};
    if (r->receive_error != MCP_OK) {
      s = r->receive_error;
      detail = r->receive_detail;
    } else if (msg->data.result != CURLE_OK)
      s = mcp_fail(&detail, MCP_SYSTEM_ERROR, 0,
                   curl_easy_strerror(msg->data.result));
    else if (r->http_status == 401 || r->http_status == 403) {
      s = mcp_fail(
          &detail, r->http_status == 401 ? MCP_AUTH_REQUIRED : MCP_HTTP_ERROR,
          0, "HTTP authorization rejected; inspect status, body and challenge");
    } else if (r->http_status >= 300 && r->http_status < 400) {
      s = mcp_fail(&detail, MCP_HTTP_ERROR, 0, "HTTP redirect rejected");
    } else if (!r->sse && !r->json_content_type) {
      s = mcp_fail(&detail, MCP_PROTOCOL_ERROR, 0,
                   "HTTP response has unsupported Content-Type");
    } else if (!r->sse && r->body.len) {
      s = mcp_dispatch(c, r, r->body.data, r->body.len, &detail);
      if (s == MCP_OK && r->status != MCP_REMOTE_ERROR &&
          (r->http_status < 200 || r->http_status >= 300))
        s = mcp_fail(&detail, MCP_HTTP_ERROR, 0,
                     "HTTP failure status with non-error MCP response");
    } else if (r->status == MCP_PENDING)
      s = mcp_fail(&detail, MCP_PROTOCOL_ERROR, 0,
                   "HTTP response ended before a final MCP response");
    if (s == MCP_OK && r->status == MCP_PENDING)
      s = mcp_fail(&detail, MCP_HTTP_ERROR, 0,
                   "HTTP response did not complete the request");
    if (s != MCP_OK) {
      if (!r->response.json && r->body.len) {
        r->response.json = malloc(r->body.len + 1);
        if (r->response.json) {
          memcpy(r->response.json, r->body.data, r->body.len);
          r->response.json[r->body.len] = 0;
          r->response.length = r->body.len;
        } else
          s = mcp_fail(&detail, MCP_NO_MEMORY, 0, "retain HTTP error body");
      }
      mcp_finish(r, s, &detail);
    }
    mcp_http_remove(r);
  }
  (void)e;
  return MCP_OK;
}
mcp_status mcp_http_poll(mcp_client *c, int ms, mcp_error *e) {
  int running = 0;
  CURLMcode code = curl_multi_perform(c->multi, &running);
  if (code != CURLM_OK)
    return mcp_fail(e, MCP_SYSTEM_ERROR, 0, "perform HTTP transfers");
  mcp_status s = http_messages(c, e);
  if (s != MCP_OK)
    return s;
  /* A final SSE frame completes a request even when the peer keeps the socket
   * open. */
  bool completed = false;
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->easy && r->status != MCP_PENDING) {
      completed = true;
      mcp_http_remove(r);
    }
  if (ms && running && !completed) {
    int count = 0;
    code = curl_multi_poll(c->multi, NULL, 0, ms, &count);
    if (code == CURLM_OK)
      code = curl_multi_perform(c->multi, &running);
    if (code != CURLM_OK)
      return mcp_fail(e, MCP_SYSTEM_ERROR, 0, "poll HTTP transfers");
    s = http_messages(c, e);
  }
  for (mcp_request *r = c->requests; r; r = r->next)
    if (r->easy && r->status != MCP_PENDING)
      mcp_http_remove(r);
  return s;
}
