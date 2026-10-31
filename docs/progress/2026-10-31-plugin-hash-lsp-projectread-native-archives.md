# 2026-10-31 - Interface hash (K0104), plugin items in the LSP, ProjectRead symlinks, native release inputs

Four issues, one PR; decisions D287-D290.

- **#8468** `Std.File.realPath` with a twin on each kernel; `ProjectRead.readText`
  resolves the file and the granted root and refuses a link that leaves the root.
  Tests: `file_tests.l`, `generator_self_test.l`.
- **#8486** `K0104`: `Lyric.PluginExpand` hashes each point and capability; the
  hash is in `PointInfo`/`CapabilityInfo`, the manifest and `plugin/hello`;
  `registerPlugin` and the handshake refuse a mismatch; `lyric plugin check --api`
  compares against the host's API package. Tests: `plugin_expand_self_test.l`,
  `plugin_manifest_tests.l`.
- **#8488** The language server runs `PluginExpand` (own and imported packages),
  so generated names resolve and K-diagnostics are published. Tests:
  `lsp_self_test.l`.
- **#8454** Release archives carry `lib/std/` and the native runtime; the native
  loader reads `lib/std`; a release smoke step builds a native program from the
  unpacked archive.
