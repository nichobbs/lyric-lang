# Plugin signing tools: Std.PluginSign and `lyric plugin keygen`/`sign`/`verify` (D248, D263, plugins P7)

The second piece of plugin signing, after `Std.Ed25519`:

- `lyric-stdlib/std/plugin_sign.l` adds `Std.PluginSign`: the canonical listing (`listingPaths`, `artifactListing`,
  `listingPathProblem`), the signed message (`signedMessage`), `plugin.sig` (`parsePluginSignature`,
  `pluginSignatureToJson`, `readPluginSignature`, `writePluginSignature`), keys (`formatPublicKey`,
  `parsePublicKey`, `formatSecretKey`, `parseSecretKey`, `publicKeyId`), `signArtifact`, `verifyArtifact`
  (K0105-K0110 as `SignatureProblem`) and `checkSignatureStructure` for `lyric plugin check`.
- `Std.File` gains `entryKind` (the entry itself, without following a link: `RegularFile`, `Directory`,
  `SymbolicLink`, `Other`, `Missing`) and `listEntries` (every entry of a directory, dangling links included), over
  new kernel seams on all three targets. `lyric-rt` adds `lyric_path_kind_nofollow` (lstat, and the reparse-point
  attributes on Windows) with a C test. .NET cannot tell a FIFO or device from a regular file (#8578).
- `lyric plugin keygen -o <base>` writes an owner-only secret key and a public key; `lyric plugin sign <dir>` checks
  and signs an artifact (key from `--key` or `LYRIC_PLUGIN_SIGNING_KEY`); `lyric plugin verify <dir> --key <pub>...
  [--publisher <name>]` verifies as a host will; `lyric plugin pack --sign-key <file>` signs while packing;
  `lyric plugin check` also checks `plugin.sig`.
- D263 narrows listing paths to printable ASCII other than `\`: native has no Unicode normalization, and a JVM in
  the POSIX locale reads non-ASCII file names as `?`, so the D248 NFC rule could not be applied or relied on.

Tests: `lyric-stdlib/tests/plugin_sign_tests.l` (12 cases: keys, path rules, ordering, case collisions, links, a
round trip and each of K0105-K0110) on dotnet, the JVM and native; `file_tests.l` covers `entryKind` and
`listEntries`; `scripts/ci/plugin-sign-e2e.sh` drives the CLI, including `pack --sign-key` on the `trusted_notes`
fixture. Writing the module surfaced three native codegen gaps, filed as #8579.
