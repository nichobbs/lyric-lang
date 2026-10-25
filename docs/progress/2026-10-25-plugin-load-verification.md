# Plugin hosts verify signatures at load (D248, D264, plugins P7)

`discoverPlugins` now verifies every artifact directory's `plugin.sig` before reading its manifest, on dotnet, the
JVM and native hosts:

- `PluginHostConfig.trust` takes a `TrustPolicy` (`keys`, `revokedKeyIds`, `allowUnsigned`), built with `trustKeys`
  or `trustKeysAllowingUnsigned`. Without one a host trusts no keys and loads nothing it discovers.
- A refused artifact is a `PluginLoadIssue` with `K0105` (unsigned or unreadable `plugin.sig`), `K0106`, `K0107`,
  `K0108`, `K0109` or `K0110`. A verified plugin's `PluginManifest.signer` carries its publisher and key id to the
  `GrantPolicy`.
- An unsigned plugin a development host allows never runs in process; a damaged signature is never treated as
  unsigned. `registerPlugin` still takes the caller's word (D264).
- `Std.PluginSign.verifyArtifact` lets one key be trusted for several publisher names.

The e2e suites (`plugin_e2e_tests.l`, `plugin_generated_e2e_tests.l`, `plugin_trusted_e2e_tests.l`,
`plugin_component_e2e_tests.l`) sign their fixtures with the published example key
(`examples/plugins/keys/example-publisher.key`) and pin it. New cases cover K0105, K0106, K0108 and K0110, an
unsigned plugin under `allowUnsigned`, the signer reaching the policy, and an unsigned plugin the policy trusts still
running in its own process. The LSP editor and the lyric-ui widget hosts pin the example key, and
`scripts/ci/plugin-lsp-e2e.sh` and `scripts/ci/ui-widget-plugins-e2e.sh` sign the artifacts they build.
