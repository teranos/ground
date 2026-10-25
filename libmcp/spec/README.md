# Specification and independent oracle

`PINNED.json` identifies the exact official specification and Python SDK source
commits used. `2026-07-28.json` is copied verbatim from that specification;
`LICENSE` preserves its upstream licensing notice. Library source remains under
Ground's MIT license. Dependency and oracle versions are explicit; upgrading the
protocol requires a new coverage review, not changing a date string alone.

To reproduce the independent interoperability tests (Python 3.12):

```sh
git clone https://github.com/modelcontextprotocol/python-sdk /tmp/mcp-python-sdk
git -C /tmp/mcp-python-sdk checkout 2af9e3089ac66b35c1550c500aae86a82efb1e17
python3 -m venv /tmp/mcp-interop
/tmp/mcp-interop/bin/python -m pip install -r tests/interop-requirements.txt
make test-interop SDK_ROOT=/tmp/mcp-python-sdk SDK_PYTHON=/tmp/mcp-interop/bin/python
```

The test refuses a different SDK HEAD or a changed schema hash. It runs actual
SDK stdio and HTTP servers, exercising modern discovery, legacy initialization,
tool listing and calls over both JSON and SSE. The SDK model results are also
checked against the pinned JSON Schema with a separate 2020-12 validator. This
validator is a test dependency, never a Python runtime dependency of libMCP.
