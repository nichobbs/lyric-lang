# D264 - Plugin hosts verify signatures at load: the host surface (refines D248 Decision 6)

**Status:** shipped. Refines D248 Decision 6 (docs/69 §8, §12); plugins P7.

## Context

D248 Decision 6 specified load-time verification with `PluginHostConfig.trust:
TrustPolicy` holding pinned keys, followed catalogues and `unsigned` (`Refuse`
or `AllowSandboxed`), and said the policy's input gains the signer.
Implementing it in `Std.Plugin` on dotnet, the JVM and native settled the
surface below.

## Decision

1. **`trust: Option[TrustPolicy] = None`.** No `trust` means no trusted keys
   and no unsigned plugins: `discoverPlugins` refuses everything. The field is
   an `Option` because a record-field default that calls a function from
   another package does not compile on `--target native` (#8579); `None` is
   the portable default, and `trustNoKeys()` names the same policy.
2. **`TrustPolicy { keys, revokedKeyIds, allowUnsigned: Bool = false }`.**
   D248's `Refuse | AllowSandboxed` is a `Bool`, so a host never names an enum
   case from another package (also #8579). `trustKeys(keys)` and
   `trustKeysAllowingUnsigned(keys)` build the two common policies; P8 adds
   catalogues to the record.
3. **The signer travels on the manifest.** `PluginManifest` gains `signer:
   Option[PluginSigner] = None`, set by `discoverPlugins` after verification
   and never read from `plugin.json`, so `GrantPolicy.decide(manifest)` keeps
   its signature and every existing policy keeps compiling.
4. **Only a missing `plugin.sig` is "unsigned".** `Std.PluginSign` reports it
   as `MissingSignature`, distinct from `MalformedSignature`; with
   `allowUnsigned`, only the former loads (with no signer). A damaged,
   untrusted or revoked signature is refused either way.
5. **An unsigned plugin never runs in process.** It loads through a process,
   wasm or component payload even when the policy marks it trusted; one that
   ships only a trusted payload for the host is refused with `K0105`.
6. **`registerPlugin` checks no signature.** It registers a manifest the
   caller built or probed itself, such as the compiler's freshly built
   generators; the caller vouches for it. Only `discoverPlugins`, which reads
   directories, verifies.
7. **One key may be trusted for several publishers.** Every `TrustedKey` with
   the signature's key id that verifies is kept, and the one whose publisher
   is the manifest's is the signer; otherwise `K0109` names each publisher
   the key is trusted for.
8. **Issue kinds.** `PluginIssueKind` gains `SignatureMissing` (K0105),
   `SigningKeyUntrusted` (K0106), `SignatureInvalid` (K0107),
   `ArtifactFilesChanged` (K0108), `ArtifactIdentityMismatch` (K0109) and
   `SigningKeyRevoked` (K0110). The issue names the plugin id read leniently
   from `plugin.json`, before the manifest is validated.
9. **Examples and tests sign with a published key.**
   `examples/plugins/keys/example-publisher.key` (and `.pub`) is checked in
   for the examples and CI only. The example hosts pin its public key in
   source, as an application pins its publishers' keys, and the e2e suites
   sign their fixtures with it.
10. **Generators.** The compiler takes source generators only from path and
    workspace dependencies and builds them from source (docs/40 §4.2), which
    D248 Decision 7 exempts from signing. Signed `lyric.lock` entries apply
    once a generator can be restored as a packed artifact from the registry
    or git; that work is tracked in #8580.
