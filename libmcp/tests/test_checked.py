"""An invalid model call must never reach the server. Responses remain intact."""
import ctypes as C
import json
import unittest
import test_http as http
from test_schema import Options, wire
base, lib = http.base, http.lib
lib.mcp_tool_compile.argtypes=[C.c_char_p,C.POINTER(Options),C.POINTER(C.c_void_p),C.POINTER(base.Response),C.POINTER(base.Error)]
lib.mcp_tool_destroy.argtypes=[C.c_void_p]
lib.mcp_tool_submit.argtypes=[C.c_void_p,C.c_void_p,C.c_char_p,C.c_int,C.POINTER(C.c_void_p),C.POINTER(base.Error)]
lib.mcp_request_validation_json.argtypes=[C.c_void_p]
lib.mcp_request_validation_json.restype=C.c_char_p

class Checked(unittest.TestCase):
    setUpClass=classmethod(http.HTTP.setUpClass.__func__)
    tearDownClass=classmethod(http.HTTP.tearDownClass.__func__)
    setUp=http.HTTP.setUp
    tearDown=http.HTTP.tearDown
    finish=http.HTTP.finish
    request=http.HTTP.request
    def compile(self, output=None, name="echo"):
        t=C.c_void_p()
        definition={'name':name,'inputSchema':{'type':'object','properties':{'x':{'type':'integer'}},'required':['x']}}
        if output is not None: definition['outputSchema']=output
        self.assertEqual(lib.mcp_tool_compile(wire(definition),None,C.byref(t),C.byref(self.response),C.byref(self.error)),0,self.error.message)
        self.addCleanup(lib.mcp_tool_destroy,t)
        return t
    def submit(self,t,args):
        r=C.c_void_p()
        self.assertEqual(lib.mcp_tool_submit(self.client,t,wire(args),1000,C.byref(r),C.byref(self.error)),0,self.error.message)
        self.addCleanup(lib.mcp_request_destroy,r,None)
        return r
    def test_invalid_input_is_local_then_corrected_call_succeeds(self):
        t=self.compile()
        before=len(self.server.observed)
        r=self.submit(t,{'x':'wrong'})
        self.assertEqual(lib.mcp_request_status(r),18)
        self.assertEqual(len(self.server.observed),before)
        report=json.loads(lib.mcp_request_validation_json(r))
        self.assertEqual(report['phase'],'input')
        self.assertTrue(any(x['instanceLocation']=='/x' for x in report['errors']))
        good=self.submit(t,{'x':3})
        self.assertEqual(self.finish(good),0)
        self.assertEqual(len(self.server.observed),before+1)
        self.assertEqual(json.loads(lib.mcp_request_validation_json(r)),report)
    def test_missing_structured_output_retains_wire_response(self):
        t=self.compile({'type':'object'})
        r=self.submit(t,{'x':1})
        self.assertEqual(self.finish(r),18)
        self.assertEqual(lib.mcp_request_take(r,C.byref(self.response),C.byref(self.error)),18)
        self.assertEqual(self.response.value()['result']['content'][0]['text'],'ok')
        self.assertEqual(json.loads(lib.mcp_request_validation_json(r))['phase'],'output')
        self.assertEqual(self.request('ping'),0)
    def test_structured_values_and_tool_errors(self):
        for schema, value, expected in [
            ({'type':'integer'}, 5, 0),
            ({'type':'integer'}, '5', 18),
            ({'type':'null'}, None, 0),
            ({'type':'array','items':{'type':'integer'}}, [1,2], 0),
            ({'type':'array','items':{'type':'integer'}}, [1,'2'], 18),
        ]:
            with self.subTest(schema=schema,value=value):
                t=self.compile(schema, 'checked-output')
                r=self.submit(t,{'x':1,'value':value})
                self.assertEqual(self.finish(r),expected)
                self.assertEqual(lib.mcp_request_take(r,C.byref(self.response),C.byref(self.error)),expected)
                self.assertEqual(self.response.value()['result']['structuredContent'],value)
                lib.mcp_response_free(C.byref(self.response))
        t=self.compile({'type':'integer'}, 'checked-output')
        r=self.submit(t,{'x':1,'value':'server failed','error':True})
        self.assertEqual(self.finish(r),11)
        self.assertIsNone(lib.mcp_request_validation_json(r))

    def test_request_retains_schema_after_tool_destroyed(self):
        t=self.compile({'type':'object'})
        r=self.submit(t,{'x':1})
        lib.mcp_tool_destroy(t); t.value=None
        self.assertEqual(self.finish(r),18)

if __name__=='__main__': unittest.main()
