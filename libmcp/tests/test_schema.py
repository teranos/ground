"""Public C ABI tests: schemas are compiled once; validation never coerces data."""
import ctypes as C
import json
import unittest
import test_mcp as base

lib = base.lib
class Options(C.Structure):
    _fields_ = [("max_bytes", C.c_size_t), ("max_depth", C.c_uint),
                ("pattern_timeout_ms", C.c_uint), ("resources_json", C.c_char_p)]
lib.mcp_schema_options_init.argtypes = [C.POINTER(Options)]
lib.mcp_schema_compile.argtypes = [C.c_char_p, C.POINTER(Options), C.POINTER(C.c_void_p), C.POINTER(base.Response), C.POINTER(base.Error)]
lib.mcp_schema_validate.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(base.Response), C.POINTER(base.Error)]
lib.mcp_schema_destroy.argtypes = [C.c_void_p]

def wire(x):
    return json.dumps(x, ensure_ascii=False, separators=(",", ":")).encode()

class Schema(unittest.TestCase):
    def setUp(self):
        self.schema = C.c_void_p()
        self.report = base.Response()
        self.error = base.Error()
        self.options = Options()
        lib.mcp_schema_options_init(C.byref(self.options))
    def tearDown(self):
        lib.mcp_response_free(C.byref(self.report))
        lib.mcp_schema_destroy(self.schema)
    def compile(self, schema):
        return lib.mcp_schema_compile(wire(schema), C.byref(self.options), C.byref(self.schema), C.byref(self.report), C.byref(self.error))
    def validate(self, value):
        lib.mcp_response_free(C.byref(self.report))
        return lib.mcp_schema_validate(self.schema, wire(value), C.byref(self.report), C.byref(self.error))
    def test_precise_error_and_reuse(self):
        self.assertEqual(self.compile({"type":"object", "properties":{"count":{"type":"integer","minimum":1}},"required":["count"]}), 0)
        self.assertEqual(self.validate({"count":"wrong"}), 18)
        report = self.report.value()
        self.assertFalse(report['valid'])
        self.assertTrue(any(e['instanceLocation']=='/count' and 'type' in e['schemaLocation'] for e in report['errors']))
        self.assertEqual(self.validate({"count":2}), 0)
    def test_invalid_schema_is_not_an_invalid_instance(self):
        self.assertEqual(self.compile({"type":42}), 17)
        self.assertFalse(self.schema)
        self.assertEqual(self.report.value()['phase'], 'schema')
    def test_unknown_dialect(self):
        self.assertEqual(self.compile({"$schema":"https://example.invalid/draft"}), 12)
        self.assertFalse(self.schema)
    def test_no_implicit_remote_fetch(self):
        self.assertEqual(self.compile({"$ref":"https://example.invalid/schema"}),17)
        self.assertFalse(self.schema)
    def test_explicit_resource(self):
        self.options.resources_json=wire({"https://example.invalid/schema":{"type":"integer"}})
        self.assertEqual(self.compile({"$ref":"https://example.invalid/schema"}),0)
        self.assertEqual(self.validate(4),0)
        self.assertEqual(self.validate("4"),18)
    def test_unevaluated_and_dynamic_refs(self):
        self.assertEqual(self.compile({"$id":"https://example.invalid/tree","$dynamicAnchor":"node","type":"object","properties":{"value":{"type":"integer"},"child":{"$dynamicRef":"#node"}},"unevaluatedProperties":False}),0)
        self.assertEqual(self.validate({"value":1,"child":{"value":2}}),0)
        self.assertEqual(self.validate({"child":{"extra":1}}),18)
    def test_local_refs_and_escaped_locations(self):
        self.assertEqual(self.compile({"$defs":{"n":{"type":"integer"}},"properties":{"a/b~c":{"$ref":"#/$defs/n"}}}),0)
        self.assertEqual(self.validate({"a/b~c":False}),18)
        self.assertTrue(any(e['instanceLocation']=='/a~1b~0c' for e in self.report.value()['errors']))
    def test_format_is_annotation_by_default(self):
        self.assertEqual(self.compile({"type":"string","format":"email"}),0)
        self.assertEqual(self.validate("not an email"),0)
    def test_input_size_limit(self):
        self.options.max_bytes=128
        self.assertEqual(self.compile(True),0)
        self.assertEqual(self.validate("x"*256),9)
    def test_recursion_limit_is_not_invalid(self):
        self.options.max_depth=8
        self.assertEqual(self.compile({"$ref":"#"}),0)
        self.assertEqual(self.validate({}),19)
        self.assertIsNone(self.report.value()['valid'])
    def test_zero_limits_are_rejected(self):
        self.options.max_depth=0
        self.assertEqual(self.compile(True),1)
    def test_schema_null_rejected_but_instance_null_valid(self):
        self.assertEqual(self.compile({"type":"null"}),0)
        self.assertEqual(self.validate(None),0)
        self.assertEqual(self.validate(False),18)

if __name__ == '__main__':
    unittest.main()
