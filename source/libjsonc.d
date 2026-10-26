module libjsonc;

// json-c headers, linked from the same pinned json_c as libmcp.
extern(C) nothrow @nogc {
    struct json_object;
    struct json_tokener;
    enum json_type : int { null_, boolean, double_, int_, object, array, string_ }
    json_type json_object_get_type(const(json_object)*);
    int json_object_object_get_ex(const(json_object)*, const(char)*, json_object**);
    size_t json_object_array_length(const(json_object)*);
    json_object* json_object_array_get_idx(const(json_object)*, size_t);
    const(char)* json_object_get_string(json_object*);
    int json_object_get_string_len(const(json_object)*);
    int json_object_get_boolean(const(json_object)*);
    double json_object_get_double(const(json_object)*);
    long json_object_get_int64(const(json_object)*);
    int json_object_put(json_object*);
    json_tokener* json_tokener_new_ex(int);
    void json_tokener_set_flags(json_tokener*, int);
    json_object* json_tokener_parse_ex(json_tokener*, const(char)*, int);
    int json_tokener_get_error(json_tokener*);
    size_t json_tokener_get_parse_end(json_tokener*);
    void json_tokener_free(json_tokener*);
    // A value's own JSON, kept by the value until it is put.
    const(char)* json_object_to_json_string_ext(json_object*, int);
}

enum JSON_C_TO_STRING_PLAIN = 0;

json_object* jsonField(json_object* object, const(char)* name) nothrow @nogc {
    json_object* value;
    if (json_object_get_type(object) == json_type.object)
        json_object_object_get_ex(object, name, &value);
    return value;
}

json_object* parseJson(const(char)[] text) nothrow @nogc {
    if (text.length > int.max) return null;
    foreach (c; text) if (c == 0) return null;
    auto tok = json_tokener_new_ex(64);
    if (tok is null) return null;
    scope(exit) json_tokener_free(tok);
    json_tokener_set_flags(tok, 0x01 | 0x10); // STRICT | VALIDATE_UTF8
    auto value = json_tokener_parse_ex(tok, text.ptr, cast(int) text.length);
    if (json_tokener_get_error(tok) != 0 || json_tokener_get_parse_end(tok) != text.length) {
        json_object_put(value);
        return null;
    }
    return value;
}
