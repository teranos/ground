/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

mcp_status mcp_fail(mcp_error *e, mcp_status code, int sys, const char *text) {
  if (e)
    *e = (mcp_error){.code = code, .system_errno = sys, .message = text};
  return code;
}

bool mcp_has(json *o, const char *key) {
  json *v = NULL;
  return json_object_is_type(o, json_type_object) &&
         json_object_object_get_ex(o, key, &v);
}
json *mcp_field(json *o, const char *key) {
  json *v = NULL;
  if (json_object_is_type(o, json_type_object))
    json_object_object_get_ex(o, key, &v);
  return v;
}
bool mcp_string_is(json *o, const char *s) {
  return json_object_is_type(o, json_type_string) &&
         (size_t)json_object_get_string_len(o) == strlen(s) &&
         !memcmp(json_object_get_string(o), s, strlen(s));
}
bool mcp_add(json *o, const char *key, json *v) {
  if (!o || !v || json_object_object_add(o, key, v) != 0) {
    json_object_put(v);
    return false;
  }
  return true;
}

/* RFC 3629: reject overlong encodings, surrogates and values above U+10FFFF.
 * json-c's UTF8 flag checks continuation shape but not all these constraints.
 */
static bool utf8(const unsigned char *s, size_t n) {
  for (size_t i = 0; i < n;) {
    unsigned a = s[i++];
    if (a < 0x80)
      continue;
    unsigned count, minimum, value;
    if (a >= 0xc2 && a <= 0xdf) {
      count = 1;
      minimum = 0x80;
      value = a & 31;
    } else if (a >= 0xe0 && a <= 0xef) {
      count = 2;
      minimum = 0x800;
      value = a & 15;
    } else if (a >= 0xf0 && a <= 0xf4) {
      count = 3;
      minimum = 0x10000;
      value = a & 7;
    } else
      return false;
    if (n - i < count)
      return false;
    while (count--) {
      unsigned b = s[i++];
      if ((b & 0xc0) != 0x80)
        return false;
      value = (value << 6) | (b & 63);
    }
    if (value < minimum || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff))
      return false;
  }
  return true;
}
static bool digit(unsigned char c) { return c >= '0' && c <= '9'; }
static bool space(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}
/* Validate lexical tokens as RFC 8259 JSON before json-c checks structure.
 * This excludes its accepted NaN/Infinity, single-quoted keys, leading-zero
 * numbers, raw controls in keys and truncated/embedded-NUL strings. */
static bool lex(const char *s, size_t n) {
  for (size_t i = 0; i < n;) {
    unsigned char c = (unsigned char)s[i++];
    if (space(c) || strchr("{}[]:,", c)) {
      if (!c)
        return false;
      continue;
    }
    if (c == '"') {
      bool ended = false;
      while (i < n) {
        c = (unsigned char)s[i++];
        if (c < 0x20)
          return false;
        if (c == '"') {
          ended = true;
          break;
        }
        if (c == '\\' && ++i > n)
          return false;
      }
      if (!ended)
        return false;
    } else if (c == '-' || digit(c)) {
      size_t start = i - 1;
      if (c == '-') {
        if (i == n || !digit((unsigned char)s[i]))
          return false;
        c = (unsigned char)s[i++];
      }
      if (c != '0')
        while (i < n && digit((unsigned char)s[i]))
          i++;
      if (i < n && s[i] == '.') {
        i++;
        if (i == n || !digit((unsigned char)s[i]))
          return false;
        while (i < n && digit((unsigned char)s[i]))
          i++;
      }
      if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < n && (s[i] == '+' || s[i] == '-'))
          i++;
        if (i == n || !digit((unsigned char)s[i]))
          return false;
        while (i < n && digit((unsigned char)s[i]))
          i++;
      }
      if (i == start ||
          (i < n && !space((unsigned char)s[i]) && !strchr(",]}", s[i])))
        return false;
    } else {
      const char *word = c == 't'   ? "true"
                         : c == 'f' ? "false"
                         : c == 'n' ? "null"
                                    : NULL;
      if (!word)
        return false;
      size_t k = strlen(word) - 1;
      if (n - i < k || memcmp(s + i, word + 1, k))
        return false;
      i += k;
    }
  }
  return true;
}

mcp_status mcp_parse(const char *s, size_t n, json **out, mcp_error *e) {
  *out = NULL;
  if (!s || !n || n >= INT_MAX || memchr(s, 0, n) ||
      !utf8((const unsigned char *)s, n) || !lex(s, n))
    return mcp_fail(e, MCP_PROTOCOL_ERROR, 0, "invalid JSON text or UTF-8");
  struct json_tokener *t = json_tokener_new_ex(128);
  if (!t)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate JSON parser");
  json_tokener_set_flags(t, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
  /* Include NUL so primitive JSON values also finish. Copying avoids reading
   * beyond a caller's length-delimited, non-terminated buffer. */
  char *copy = malloc(n + 1);
  if (!copy) {
    json_tokener_free(t);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate JSON input");
  }
  memcpy(copy, s, n);
  copy[n] = 0;
  json *v = json_tokener_parse_ex(t, copy, (int)n + 1);
  enum json_tokener_error error = json_tokener_get_error(t);
  size_t end = json_tokener_get_parse_end(t);
  free(copy);
  json_tokener_free(t);
  if (error != json_tokener_success || end < n) {
    json_object_put(v);
    return mcp_fail(
        e,
        error == json_tokener_error_memory ? MCP_NO_MEMORY : MCP_PROTOCOL_ERROR,
        0,
        error == json_tokener_error_memory ? "JSON parser allocation failed"
                                           : "malformed JSON structure");
  }
  *out = v;
  return MCP_OK;
}

mcp_status mcp_buffer_append(mcp_buffer *b, const char *s, size_t n,
                             size_t limit, mcp_error *e) {
  if (n > limit || b->len > limit - n)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0,
                    "buffer exceeds configured message limit");
  size_t need = b->len + n + 1;
  if (need > b->capacity) {
    size_t cap = need <= limit / 2 ? need * 2 : limit + 1;
    char *p = realloc(b->data, cap);
    if (!p)
      return mcp_fail(e, MCP_NO_MEMORY, 0, "grow message buffer");
    b->data = p;
    b->capacity = cap;
  }
  if (n)
    memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
  return MCP_OK;
}
void mcp_buffer_free(mcp_buffer *b) {
  free(b->data);
  *b = (mcp_buffer){0};
}
