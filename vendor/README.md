# Native schema dependency provenance

Selected source files from https://github.com/corvus-dotnet/Corvus.JsonSchema
commit `4fcedcfef95c869a7477df64d8114c83266595ae`:

- `src-rs/corvus-json-schema` → `corvus/corvus-json-schema` (0.1.7)
- `src-rs/corvus-json-schema-capi` → `corvus/corvus-json-schema-capi` (0.1.4)

Corvus code is copied without functional changes. Cargo manifests, lockfiles,
headers, build script, source, licenses and available notices are retained.
`crates/` is Cargo's vendored dependency closure, including checksums and license
files; `.cargo/config.toml` redirects crates.io to this local source. Build with
`cargo build --offline --locked` through the Makefile. No compiled targets are
included in the source package. Rust minimum declared by Corvus is 1.89.

API reference: https://corvus-oss.org/Corvus.JsonSchema/docs/json-schema-for-c.html
The static archive merges the C wrapper and native validator. Downstream linking
still needs json-c, curl and platform system libraries listed by pkg-config.
