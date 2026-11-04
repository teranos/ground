#ifndef ACP_INTERNAL_H
#define ACP_INTERNAL_H

#include "acp.h"

#include <json-c/json.h>

// Every key libacp reads goes through acp_field, acp_offered, acp_flag or acp_string, and
// every key it writes through json_object_object_add: parity reads both out of this source.
json_object *acp_parse(const char *json, size_t length);
// The caller's JSON as a value, written back as it was given when it is on one line; text
// that is no JSON is the string it is. 0 only when out of memory; *out is NULL for JSON null.
int acp_raw(const char *text, json_object **out);
json_object *acp_field(json_object *object, const char *key);
int acp_offered(json_object *object, const char *key);
int acp_flag(json_object *object, const char *key);
char *acp_string(json_object *object, const char *key);
// Hands object's JSON to out and puts object; ACP_NO_MEMORY when it could not be written.
acp_status acp_finish(json_object *object, acp_buffer *out);
// A tool call's locations as ACP writes them, count of them; NULL with *bad set when one is no
// absolute path, and NULL when count is 0.
json_object *acp_locations(const acp_location *locations, size_t count, int *bad);
// A -32602 saying message, in error_json; ACP_INVALID_PARAMS once it is written.
acp_status acp_invalid(acp_buffer *error_json, const char *message);

#endif
