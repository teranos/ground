"""Pinned upstream oracle, with an explicit offline document registry."""
import ctypes as C
import json
from pathlib import Path
from test_schema import lib, base, Options, wire

root=Path(__file__).parent/'schema-suite'
resources={}
for p in (root/'remotes').rglob('*.json'):
    resources['http://localhost:1234/'+p.relative_to(root/'remotes').as_posix()]=json.loads(p.read_text())
opts=Options();lib.mcp_schema_options_init(C.byref(opts))
opts.resources_json=wire(resources)
failures=[]; passed=0; excluded=[]
# Explicit API boundary: only the five standard dialect URIs are supported.
# These tests define new dialects, not schemas in the supported standard dialect.
custom_dialects = {
    "schema that uses custom metaschema with with no validation vocabulary",
    "ignore unrecognized optional vocabulary",
}
for p in sorted((root/'tests'/'draft2020-12').glob('*.json')):
    for group in json.loads(p.read_text()):
        schema=C.c_void_p(); report=base.Response(); error=base.Error()
        rc=lib.mcp_schema_compile(wire(group['schema']),C.byref(opts),C.byref(schema),C.byref(report),C.byref(error))
        if p.name == 'vocabulary.json' and group['description'] in custom_dialects and rc == 12:
            excluded.append({'file':p.name,'group':group['description'],'cases':len(group['tests']),'reason':'custom dialect explicitly rejected with MCP_UNSUPPORTED'})
        elif rc:
            failures.append({'file':p.name,'group':group['description'],'compile':rc,'report':report.value() if report.json else str(error.message)})
        else:
            for test in group['tests']:
                lib.mcp_response_free(C.byref(report))
                rc=lib.mcp_schema_validate(schema,wire(test['data']),C.byref(report),C.byref(error))
                if rc not in (0,18) or (rc==0)!=test['valid']:
                    failures.append({'file':p.name,'group':group['description'],'test':test['description'],'status':rc,'expected':test['valid'],'report':report.value() if report.json else str(error.message)})
                else: passed+=1
        lib.mcp_schema_destroy(schema);lib.mcp_response_free(C.byref(report))
print(json.dumps({'passed':passed,'failures':failures,'excluded':excluded},indent=2))
raise SystemExit(bool(failures))
