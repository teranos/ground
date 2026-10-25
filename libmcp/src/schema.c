/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include "corvus_json_schema.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct mcp_schema {
  cjs_validator *validator;
  size_t limit;
};
static const char *const dialects[] = {
  "http://json-schema.org/draft-04/schema",
  "http://json-schema.org/draft-06/schema",
  "http://json-schema.org/draft-07/schema",
  "https://json-schema.org/draft/2019-09/schema",
  "https://json-schema.org/draft/2020-12/schema"
};
void mcp_schema_options_init(mcp_schema_options *o) {
  if (o) *o = (mcp_schema_options){1024 * 1024, 128, 50, NULL};
}
void mcp_schema_destroy(mcp_schema *s) {
  if (s) { cjs_validator_free(s->validator); free(s); }
}
mcp_schema *mcp_schema_clone(const mcp_schema *s) {
  if (!s) return NULL;
  mcp_schema *copy = malloc(sizeof(*copy));
  if (!copy) return NULL;
  copy->validator = cjs_validator_clone(s->validator);
  copy->limit = s->limit;
  if (!copy->validator) { free(copy); return NULL; }
  return copy;
}
static json *str(cjs_str s) {
  return s.len <= INT_MAX ? json_object_new_string_len(s.ptr ? s.ptr : "", (int)s.len) : NULL;
}
static mcp_status save_report(json *v, size_t limit, mcp_response *out, mcp_error *e) {
  if (!v) return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate validation report");
  const char *s = json_object_to_json_string_ext(v, JSON_C_TO_STRING_PLAIN);
  mcp_status rc = !s ? mcp_fail(e, MCP_NO_MEMORY, 0, "serialize validation report")
    : strlen(s) > limit ? mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "validation report exceeds byte limit")
    : mcp_response_set(out, s, e);
  json_object_put(v);
  return rc;
}
static mcp_status engine_error(cjs_status code, const char *phase, size_t limit,
                                mcp_response *out, mcp_error *e) {
  /* Copy the backend error before any further backend operation. */
  cjs_str msg = cjs_last_error_message();
  json *v = json_object_new_object();
  bool ok = mcp_add(v, "phase", json_object_new_string(phase)) &&
    json_object_object_add(v, "valid", NULL) == 0 &&
    mcp_add(v, "engineCode", json_object_new_int64(code)) &&
    mcp_add(v, "message", str(msg)) &&
    mcp_add(v, "offset", json_object_new_int64((int64_t)cjs_last_error_offset()));
  if (!ok) { json_object_put(v); return mcp_fail(e, MCP_NO_MEMORY, 0, "build engine error"); }
  mcp_status rc = save_report(v, limit, out, e);
  if (rc != MCP_OK) return rc;
  rc = code == CJS_DEPTH_EXCEEDED || code == CJS_PATTERN_MATCH_LIMIT || code == CJS_PATTERN_TOO_LARGE
    ? MCP_VALIDATION_LIMIT : code == CJS_PANIC ? MCP_SYSTEM_ERROR
    : !strcmp(phase, "schema") ? MCP_SCHEMA_ERROR : MCP_INVALID_ARGUMENT;
  return mcp_fail(e, rc, 0, "schema engine failed; inspect validation report");
}
static mcp_status evaluate(cjs_validator *validator, const char *text, const char *phase,
                            size_t limit, mcp_response *out, mcp_error *e) {
  cjs_collector *c = cjs_collector_new(CJS_DETAILED);
  if (!c) return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate validation collector");
  bool valid = false;
  cjs_status code = cjs_validator_evaluate_json(validator, text, strlen(text), c, &valid);
  if (code != CJS_OK) {
    mcp_status rc = engine_error(code, phase, limit, out, e);
    cjs_collector_free(c); return rc;
  }
  if (valid) { cjs_collector_free(c); return mcp_fail(e, MCP_OK, 0, "success"); }
  json *v = json_object_new_object(), *errors = json_object_new_array();
  bool ok = v && errors;
  size_t bytes = 0;
  for (size_t i = 0; ok && i < cjs_collector_count(c); i++) {
    if (cjs_collector_is_match(c, i)) continue;
    cjs_str msg = cjs_collector_message(c, i), loc = cjs_collector_instance_location(c, i),
      schema = cjs_collector_schema_location(c, i), path = cjs_collector_evaluation_location(c, i);
    size_t sizes[] = {msg.len, loc.len, schema.len, path.len};
    for (size_t j = 0; j < 4; j++) {
      if (sizes[j] > limit - bytes) {
        json_object_put(v); json_object_put(errors); cjs_collector_free(c);
        return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "validation report exceeds byte limit");
      }
      bytes += sizes[j];
    }
    json *row = json_object_new_object();
    ok = mcp_add(row, "instanceLocation", str(loc)) && mcp_add(row, "schemaLocation", str(schema)) &&
      mcp_add(row, "evaluationPath", str(path)) && mcp_add(row, "message", str(msg));
    if (!ok || json_object_array_add(errors, row) != 0) { json_object_put(row); ok = false; }
  }
  cjs_collector_free(c);
  if (ok) {
    ok = mcp_add(v, "phase", json_object_new_string(phase)) &&
      mcp_add(v, "valid", json_object_new_boolean(false));
    if (ok) { ok = mcp_add(v, "errors", errors); errors = NULL; }
  }
  json_object_put(errors);
  if (!ok) { json_object_put(v); return mcp_fail(e, MCP_NO_MEMORY, 0, "build validation report"); }
  mcp_status rc = save_report(v, limit, out, e);
  if (rc != MCP_OK) return rc;
  return mcp_fail(e, !strcmp(phase, "schema") ? MCP_SCHEMA_ERROR : MCP_VALIDATION_ERROR, 0,
                  "JSON Schema validation failed; inspect validation report");
}
static const char *dialect(json *node, const char *fallback) {
  json *d = mcp_field(node, "$schema");
  if (!mcp_has(node, "$schema")) return fallback;
  if (!json_object_is_type(d, json_type_string)) return NULL;
  const char *s = json_object_get_string(d);
  size_t n = (size_t)json_object_get_string_len(d);
  if (n && s[n-1] == '#') n--;
  for (size_t i = 0; i < sizeof(dialects)/sizeof(*dialects); i++)
    if (strlen(dialects[i]) == n && !memcmp(dialects[i], s, n)) return dialects[i];
  return NULL;
}
/* Walk schema-bearing positions only: $schema inside const/examples is data.
 * Unknown dialects and required vocabularies must not silently use a fallback. */
static mcp_status check_dialects(json *node, const char *inherited, mcp_error *e) {
  if (!json_object_is_type(node, json_type_object)) return MCP_OK;
  const char *d = dialect(node, inherited);
  if (!d) return mcp_fail(e, MCP_UNSUPPORTED, 0, "unsupported JSON Schema dialect");
  json *voc = mcp_field(node, "$vocabulary");
  if (json_object_is_type(voc, json_type_object)) {
    json_object_object_foreach(voc, key, value) {
      if (!json_object_get_boolean(value)) continue;
      const char *prefix = "https://json-schema.org/draft/2020-12/vocab/";
      const char *names[] = {"core","applicator","validation","meta-data","format-annotation","format-assertion","content","unevaluated"};
      bool found = false;
      if (!strncmp(key, prefix, strlen(prefix)))
        for (size_t i = 0; i < sizeof(names)/sizeof(*names); i++)
          if (!strcmp(key + strlen(prefix), names[i])) found = true;
      if (!found) return mcp_fail(e, MCP_UNSUPPORTED, 0, "unsupported required schema vocabulary");
    }
  }
  const char *maps[] = {"$defs","definitions","properties","patternProperties","dependentSchemas","dependencies"};
  for (size_t i = 0; i < sizeof(maps)/sizeof(*maps); i++) {
    json *map = mcp_field(node, maps[i]);
    if (json_object_is_type(map, json_type_object)) {
      json_object_object_foreach(map, key, child) {
        (void)key; mcp_status rc = check_dialects(child, d, e); if (rc) return rc;
      }
    }
  }
  const char *single[] = {"items","additionalItems","additionalProperties","unevaluatedProperties","unevaluatedItems","contains","propertyNames","not","if","then","else","contentSchema"};
  for (size_t i = 0; i < sizeof(single)/sizeof(*single); i++) {
    json *child = mcp_field(node, single[i]);
    mcp_status rc = check_dialects(child, d, e); if (rc) return rc;
    if (json_object_is_type(child, json_type_array))
      for (size_t j = 0; j < json_object_array_length(child); j++) {
        rc = check_dialects(json_object_array_get_idx(child,j), d, e); if (rc) return rc;
      }
  }
  const char *arrays[] = {"allOf","anyOf","oneOf","prefixItems"};
  for (size_t i = 0; i < sizeof(arrays)/sizeof(*arrays); i++) {
    json *a = mcp_field(node, arrays[i]);
    if (json_object_is_type(a, json_type_array))
      for (size_t j = 0; j < json_object_array_length(a); j++) {
        mcp_status rc = check_dialects(json_object_array_get_idx(a,j), d, e); if (rc) return rc;
      }
  }
  return MCP_OK;
}
typedef struct { json *resources; mcp_status failure; } resolver_context;
static cjs_status resolve(void *ctx, const char *uri, size_t n, cjs_resolved *out) {
  resolver_context *context = ctx;
  json *resources = context->resources;
  json_object_object_foreach(resources, key, value) {
    if (strlen(key) == n && !memcmp(key, uri, n)) {
      mcp_error error = {0};
      mcp_status rc = check_dialects(value, dialects[4], &error);
      if (rc) {
        context->failure = rc;
        cjs_resolved_set_error(out, error.message, strlen(error.message));
        return CJS_COMPILATION_FAILED;
      }
      const char *s = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
      if (!s) return CJS_COMPILATION_FAILED;
      const char *d = dialect(value, dialects[4]);
      cjs_validator *meta = NULL;
      cjs_status code = cjs_compile_uri(d, strlen(d), NULL, &meta);
      bool valid = false;
      if (!code) code = cjs_validator_validate_json(meta, s, strlen(s), &valid);
      cjs_validator_free(meta);
      if (code || !valid) {
        const char *msg = "external schema failed metaschema validation";
        cjs_resolved_set_error(out, msg, strlen(msg));
        return CJS_COMPILATION_FAILED;
      }
      return cjs_resolved_set_json(out, s, strlen(s));
    }
  }
  return CJS_OK; /* No document supplied. Never fetch. */
}
mcp_status mcp_schema_compile(const char *text, const mcp_schema_options *opts,
                               mcp_schema **out, mcp_response *report, mcp_error *e) {
  if (out) *out = NULL;
  mcp_schema_options defaults; mcp_schema_options_init(&defaults);
  const mcp_schema_options *o = opts ? opts : &defaults;
  if (!text || !out || !report || report->json || !o->max_bytes || o->max_bytes >= INT_MAX ||
      !o->max_depth || !o->pattern_timeout_ms)
    return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid schema arguments or limits");
  if (strnlen(text, o->max_bytes + 1) > o->max_bytes)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "schema exceeds byte limit");
  json *root = NULL, *resources = NULL;
  mcp_status rc = mcp_parse(text, strlen(text), &root, e);
  if (rc) return rc;
  const char *d = dialect(root, dialects[4]);
  rc = check_dialects(root, dialects[4], e);
  if (!d || rc) { json_object_put(root); return rc ? rc : mcp_fail(e, MCP_UNSUPPORTED, 0, "unsupported schema dialect"); }
  cjs_options *options = cjs_options_new();
  if (!options) { json_object_put(root); return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate schema options"); }
  resolver_context resolver = {0};
  cjs_status code = cjs_options_set_max_depth(options, o->max_depth);
  if (!code) code = cjs_options_set_pattern_match_limit_ms(options, o->pattern_timeout_ms);
  if (o->resources_json) {
    if (strnlen(o->resources_json, o->max_bytes + 1) > o->max_bytes) rc = mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "schema resources exceed byte limit");
    else rc = mcp_parse(o->resources_json, strlen(o->resources_json), &resources, e);
    if (!rc && !json_object_is_type(resources, json_type_object)) rc = mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "schema resources must be an object");
    resolver.resources = resources;
    if (!rc && !code) code = cjs_options_set_resolver(options, resolve, &resolver, NULL);
  }
  cjs_validator *meta = NULL, *compiled = NULL;
  if (!rc && !code) code = cjs_compile_uri(d, strlen(d), options, &meta);
  if (!rc && !code) rc = evaluate(meta, text, "schema", o->max_bytes, report, e);
  if (!rc && !code) code = cjs_compile(text, strlen(text), options, &compiled);
  if (!rc && code) {
    rc = engine_error(code, "schema", o->max_bytes, report, e);
    if (resolver.failure && rc == MCP_SCHEMA_ERROR)
      rc = mcp_fail(e, resolver.failure, 0, "external schema uses an unsupported dialect or vocabulary");
  }
  cjs_validator_free(meta); cjs_options_free(options);
  json_object_put(root); json_object_put(resources);
  if (rc) { cjs_validator_free(compiled); return rc; }
  mcp_schema *s = malloc(sizeof(*s));
  if (!s) { cjs_validator_free(compiled); return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate schema handle"); }
  *s = (mcp_schema){compiled, o->max_bytes}; *out = s;
  return mcp_fail(e, MCP_OK, 0, "success");
}
mcp_status mcp_schema_validate(const mcp_schema *s, const char *text, mcp_response *report, mcp_error *e) {
  if (!s || !text || !report || report->json) return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid validation arguments");
  if (strnlen(text, s->limit + 1) > s->limit) return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "instance exceeds byte limit");
  return evaluate(s->validator, text, "instance", s->limit, report, e);
}

mcp_status mcp_validate_phase(const mcp_schema *s, const char *text, const char *phase,
                               mcp_response *report, mcp_error *e) {
  if (!s || !text || !report || report->json) return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid validation arguments");
  if (strnlen(text, s->limit + 1) > s->limit) return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "instance exceeds byte limit");
  return evaluate(s->validator, text, phase, s->limit, report, e);
}
void mcp_tool_destroy(mcp_tool *t) {
  if (t) { free(t->name); mcp_schema_destroy(t->input); mcp_schema_destroy(t->output); free(t); }
}
const char *mcp_tool_name(const mcp_tool *t) { return t ? t->name : NULL; }
mcp_status mcp_tool_compile(const char *text, const mcp_schema_options *opts, mcp_tool **out,
                             mcp_response *report, mcp_error *e) {
  if (out) *out = NULL;
  if (!text || !out || !report || report->json) return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid tool compilation arguments");
  mcp_schema_options defaults; mcp_schema_options_init(&defaults);
  size_t limit = opts ? opts->max_bytes : defaults.max_bytes;
  if (!limit || limit >= INT_MAX) return mcp_fail(e, MCP_INVALID_ARGUMENT, 0, "invalid tool byte limit");
  if (strnlen(text, limit + 1) > limit) return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0, "tool definition exceeds byte limit");
  json *root = NULL;
  mcp_status rc = mcp_parse(text, strlen(text), &root, e);
  if (rc) return rc;
  json *name = mcp_field(root, "name"), *input = mcp_field(root, "inputSchema");
  if (!json_object_is_type(name, json_type_string) || json_object_get_string_len(name) == 0 ||
      strlen(json_object_get_string(name)) != (size_t)json_object_get_string_len(name) ||
      !json_object_is_type(input, json_type_object)) {
    json_object_put(root); return mcp_fail(e, MCP_SCHEMA_ERROR, 0, "tool needs a name and object inputSchema");
  }
  mcp_tool *t = calloc(1, sizeof(*t));
  if (!t) { json_object_put(root); return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate tool"); }
  t->name = strdup(json_object_get_string(name));
  if (!t->name) rc = mcp_fail(e, MCP_NO_MEMORY, 0, "copy tool name");
  if (!rc) rc = mcp_schema_compile(json_object_to_json_string_ext(input, JSON_C_TO_STRING_PLAIN), opts, &t->input, report, e);
  if (!rc && mcp_has(root, "outputSchema"))
    rc = mcp_schema_compile(json_object_to_json_string_ext(mcp_field(root,"outputSchema"), JSON_C_TO_STRING_PLAIN), opts, &t->output, report, e);
  json_object_put(root);
  if (rc) { mcp_tool_destroy(t); return rc; }
  *out = t; return mcp_fail(e, MCP_OK, 0, "success");
}
mcp_status mcp_schema_result(mcp_request *r, json *result, mcp_error *e) {
  if (!r->output_schema || json_object_get_boolean(mcp_field(result, "isError"))) return MCP_OK;
  if (!mcp_has(result, "structuredContent")) {
    mcp_status rc = mcp_response_set(&r->validation,
      "{\"phase\":\"output\",\"valid\":false,\"errors\":[{\"instanceLocation\":\"/structuredContent\",\"schemaLocation\":\"\",\"message\":\"outputSchema requires structuredContent\"}]}", e);
    return rc ? rc : mcp_fail(e, MCP_VALIDATION_ERROR, 0, "missing structured tool output");
  }
  const char *text = json_object_to_json_string_ext(mcp_field(result,"structuredContent"), JSON_C_TO_STRING_PLAIN);
  return text ? mcp_validate_phase(r->output_schema, text, "output", &r->validation, e)
    : mcp_fail(e, MCP_NO_MEMORY, 0, "serialize structured output");
}
