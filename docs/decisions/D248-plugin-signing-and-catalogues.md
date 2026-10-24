# D248 - Plugin signing and per-application catalogues (docs/69 §12, Q-PLG-006, Q-PLG-007)

**Status:** accepted (design; not implemented). Extends D207, D231 and D247;
resolves Q-PLG-006 and Q-PLG-007. Phases P7 and P8 of docs/69 §16 implement it.

## Context

D207 deferred signing and a registry. A host loads whatever artifact
directories its owner put on its plugin path, and the manifest's `publisher`
is a claim nobody checks before `GrantPolicy` sees it. Trusted payloads (D231)
run inside the host's process with no sandbox, so for them the claim is the
only thing standing between a tampered directory and the host's address
space. Q-PLG-006 listed Sigstore, a publisher key scheme, and reusing NuGet
and Maven signing; Q-PLG-007 asked whether plugins publish through the
docs/39 channels or need their own registry.

The stdlib has `Std.Hash` (SHA-256, SHA-512) and `Std.Encoding` (hex,
base64) but no signature verification, so every option needs new
verification code on dotnet, the JVM, native (including Windows) and wasm32.

## Decision

1. **What a signature guarantees.** Integrity of every file in an artifact
   and the identity of the publisher who signed it, checked by `Std.Plugin`
   at load time, before points are matched and before `GrantPolicy` runs.
   Build provenance (which source and CI produced a payload) is not covered.

2. **Ed25519 publisher keys, in pure Lyric.** A new stdlib module
   `Std.Ed25519` implements RFC 8032 Ed25519 key generation, signing and
   verification over `Std.Hash`'s SHA-512, in Lyric with no kernel, so one
   implementation runs on every target. Verification is strict: a
   non-canonical `S` (not below the group order), a non-canonical encoding of
   `A` or `R`, or a small-order `A` is rejected. Signing handles secret
   material, so its field arithmetic and scalar multiplication have no
   secret-dependent branches or table indices; verification may be
   variable-time. The test suite runs the RFC 8032 §7.1 vectors and the
   Wycheproof EdDSA vectors on every target.

   Sigstore was rejected for v1: verifying a bundle needs X.509 chain
   parsing, ECDSA P-256, transparency-log proofs and a TUF-distributed trust
   root on four targets, it still needs a policy mapping a publisher name to
   an OIDC identity, and private or offline use needs its own instance.
   Reusing NuGet or Maven signing was rejected because those signatures cover
   the package wrapper and are checked at restore; the directory a host loads
   afterwards is unsigned. Every signature file carries a `type` field, so a
   Sigstore envelope can be added later as a second type.

3. **Keys.** A public key is written `lyric-ed25519:<base64 of 32 bytes>`.
   Its key id is the lowercase hex of the first 16 bytes of the SHA-256 of
   the 32 key bytes; the id is a lookup hint, and keys are always compared in
   full. A secret key file holds `lyric-ed25519-secret:<base64 of the 32-byte
   seed>`. `lyric plugin keygen -o <base>` writes `<base>.key` (mode 0600
   where the file system has modes) and `<base>.pub`. Secret keys are not
   passphrase-encrypted: signing is expected to run in CI from a secret store
   (`LYRIC_PLUGIN_SIGNING_KEY` holds the secret key text), as the NuGet
   signing certificate already does (docs/34).

4. **The signature file.** An artifact directory carries `plugin.sig`:

   ```json
   {
     "schema": 1,
     "type": "ed25519",
     "keyId": "3f9a...",
     "id": "acme.git-tools",
     "version": "0.4.1",
     "files": [
       { "path": "Acme.GitTools.dll", "sha256": "..." },
       { "path": "plugin.json", "sha256": "..." },
       { "path": "plugin.wasm", "sha256": "..." }
     ],
     "signature": "<base64 of 64 bytes>"
   }
   ```

   The signed message is text, so no JSON canonicalisation is needed: the
   line `lyric-plugin-sig-v1`, then the lines `type`, `id`, `version` and
   `keyId`, then one line `<sha256> <path>` per file in listing order, each
   line ending in `\n`, encoded as UTF-8. Binding `type` means a signature
   made for one type can never be read as another's. Lines must not be
   ambiguous: `id`, `version` and `keyId` already exclude control characters
   by their formats (docs/69 §7 and Decision 3), and Decision 5 excludes them
   from paths, so no field can contain a `\n` that forges an extra line.

5. **The canonical listing.** The listing is every regular file under the
   artifact directory, recursively, except `plugin.sig`:
   - paths are relative, separated by `/`, valid UTF-8 in NFC, with no empty,
     `.` or `..` segment and no C0 or C1 control character (a file named
     `p\n<digest> q` would otherwise produce the same message lines as the
     two files `p` and `q`);
   - entries are sorted by the bytes of their UTF-8 path;
   - a symbolic link, device, socket or other non-regular file anywhere in
     the directory fails signing and verification;
   - empty directories are ignored;
   - two paths that differ only in case fail signing and verification, so an
     artifact signed on a case-sensitive file system cannot change meaning on
     a case-insensitive one;
   - the executable bit is not covered: Windows has none and zip tools carry
     it inconsistently. The installer (Decision 9) sets it on the file a
     native payload's `command` names.

6. **Verification at load.** `PluginHostConfig` gains `trust: TrustPolicy`:
   pinned publisher keys (a publisher name and its public keys), the
   catalogues the host follows (Decision 8), and `unsigned`, one of `Refuse`
   (the default) or `AllowSandboxed`. For each discovered directory,
   `Std.Plugin`:
   1. reads and parses `plugin.sig` (missing or malformed: `K0105`);
   2. finds the key by `keyId` among the pinned keys and the keys of every
      followed catalogue (not found: `K0106`), and refuses a key a followed
      catalogue revokes (`K0110`);
   3. verifies the signature over the message of Decision 4 (`K0107`);
   4. recomputes the listing from disk and requires it to equal `files`
      exactly: no missing file, no extra file, no differing digest, no
      non-regular file, no path that breaks Decision 5's rules (`K0108`);
   5. requires `plugin.json`'s `id` and `version` to equal the signature's,
      and its `publisher` to be the name the key is trusted for (`K0109`);
   6. continues with the existing load steps.

   The policy's input gains the signer (publisher name and key id), so a
   `GrantPolicy` decides on a verified publisher. Under `AllowSandboxed` an
   unsigned plugin loads with no signer, but only through a process, wasm or
   component payload.

   **Trusted payloads always need a signature** from a trusted key, whatever
   `unsigned` says; there is no opt-out. A developer signs a local build with
   a key from `lyric plugin keygen` and pins its public key in the host.

   Component payloads (§9.3) are compiled by the in-process runtime from the
   bytes the host hashed, so what runs is what was verified. Process, wasm
   (`wasmtime run`) and trusted payloads are executed or loaded by path, so a
   writer with access to the plugin directory could replace a file between
   verification and execution. That writer already controls the host, and
   this is outside the threat model.

   This changes behaviour for existing hosts: a host that sets no trust
   refuses every plugin. The repository's examples and CI end-to-end scripts
   sign their artifacts with a checked-in test key and pin its public key.

7. **Build-time generators.** A generator restored as a package (rather than
   built from source in the workspace) carries `plugin.sig` like any
   artifact. `lyric.lock` records the signer's key id beside the existing
   checksum when the generator is first resolved; later resolves require the
   same key, `--locked` fails on a change, and accepting a new key needs an
   explicit `lyric restore --update <generator>`, which shows up in the lock
   file's diff. Generators built from workspace source are the project's own
   code and are not signed.

8. **Per-application catalogues, not a global registry.** Plugins exist for
   one application's plugin points, so a single index across applications
   would mix unrelated ecosystems; plugins are therefore not published
   through the docs/39 channels. Instead, each application, or anyone
   serving its users, publishes a catalogue: two static files that any web
   server, object store or GitHub Pages site can serve, with nothing for the
   project to operate.

   `catalogue.json`:

   ```json
   {
     "schema": 1,
     "name": "acme-editor",
     "serial": 42,
     "expires": "2026-12-01T00:00:00Z",
     "catalogueKey": "lyric-ed25519:...",
     "publishers": [ { "name": "acme", "keys": ["lyric-ed25519:..."] } ],
     "revokedKeys": ["3f9a..."],
     "plugins": [
       { "id": "acme.git-tools", "version": "0.4.1", "publisher": "acme",
         "points": [ { "point": "Editor.Api.EditorExtension", "version": "1.2" } ],
         "url": "artifacts/acme.git-tools-0.4.1.zip",
         "sha256": "<digest of the zip>",
         "sigSha256": "<digest of plugin.sig>",
         "yanked": false }
     ]
   }
   ```

   `catalogue.sig` is a list of `{ "type", "keyId", "signature" }` objects,
   each an Ed25519 signature over the line `lyric-plugin-catalogue-v1`
   followed by the raw bytes of `catalogue.json`; signing raw bytes avoids
   canonicalising JSON. A relative `url` resolves against the catalogue's
   URL. `sha256` lets the installer check a download before opening it as a
   zip; `sigSha256` binds the entry to the signed contents.

   A host follows a catalogue by its URL and a pinned catalogue key, and keeps
   state for it in a directory it names: the last verified `catalogue.json`,
   its serial and the current catalogue key. A fetched catalogue is refused
   if no signature in `catalogue.sig` verifies under the current key
   (`K0120`), if it has expired (`K0121`), or if its serial is lower than the
   stored one, or equal with different bytes (`K0122`).

   Expiry blocks installs and updates from that catalogue. Loading already
   installed plugins continues with the last verified catalogue's keys and
   revocations, and the host reports a `CatalogueStale` warning that the
   application can show: an offline machine keeps working, and the
   application decides how to present the risk that a revocation it has not
   seen exists.

9. **Zip for transfer.** An artifact still loads as a directory (D207
   Decision 5); for download it is a zip named `<id>-<version>.zip` whose
   entries sit under a top-level `<id>-<version>/` directory. A new
   `Std.Zip` (pure Lyric, reading and writing stored and deflate entries)
   replaces the JVM backend's private zip and deflate readers. Extraction
   refuses absolute paths, `..` segments, symbolic links, duplicate names,
   names that differ only in case, entries outside the top-level directory,
   and archives whose total uncompressed size or compression ratio exceeds
   the installer's limits. The installer checks the zip's `sha256` against
   the catalogue entry, extracts into a temporary directory beside the
   destination, verifies the result as in Decision 6 and checks
   `plugin.sig`'s digest against `sigSha256` (`K0123`), sets the executable
   bit (Decision 5), and renames the directory into place. A yanked version
   is never installed; an installed yanked version keeps loading.

10. **One catalogue key, rotated through the catalogue.** A catalogue is
    signed by one key. To rotate, the owner publishes a catalogue whose
    `catalogueKey` names the new key and whose `catalogue.sig` carries
    signatures by both the old and the new key. A host that verifies it under
    its current key and finds a valid signature by the named new key stores
    the new key as current; the key pinned in the application's
    configuration is only the starting point. Rotations do not chain for a
    host that missed one: a catalogue is verified only under the host's
    current key, so a catalogue signed only by a key two rotations on fails
    with `K0120`. A catalogue owner therefore keeps signing with both keys
    for a transition window at least as long as the catalogue's expiry
    interval, so every host that is not already stale sees the rotation; a
    host that misses it anyway is re-pinned by an update of the application
    that carries the new key. Publisher keys are rotated and
    revoked only through the catalogue: the owner adds the new key to the
    publisher's `keys` (both may be listed during a transition), then removes
    the old one or adds its id to `revokedKeys`. `plugin.sig` carries no key
    chain.

11. **Tooling.**
    - `lyric plugin keygen -o <base>`
    - `lyric plugin sign <dir> --key <file>` (or `LYRIC_PLUGIN_SIGNING_KEY`)
      writes `plugin.sig`, after running every `lyric plugin check` rule;
      `lyric plugin pack --sign-key <file>` signs as its last step, and
      `--zip` also writes the transfer zip.
    - `lyric plugin verify <dir|zip> [--key <pub>]... [--catalogue <file|url> --catalogue-key <pub>]`
    - `lyric plugin check` validates `plugin.sig`'s structure and the
      listing without needing a key.
    - `lyric plugin catalogue init|add|yank|revoke-key|publisher|sign`
      maintain a catalogue; `sign` increments `serial` and sets `expires`
      (`--expires-in`, default 90 days).
    - `lyric plugin install <id>[@<version>] --catalogue <url> --catalogue-key <pub> --into <dir>`
    - `Std.Plugin` gains the matching host API: fetching and verifying a
      catalogue, listing its entries for the host's points, installing an
      entry, and verifying an artifact directory.

    Plugins built with the generated C#, Java or TypeScript SDKs (§13) are
    signed with `lyric plugin sign` like any directory; signing does not
    depend on the language a payload was built from.

## Diagnostics

Load issues (`PluginLoadIssue`, `pluginIssueCode`):

| Code | Meaning |
|---|---|
| K0105 | Missing or malformed `plugin.sig` (and unsigned plugins are refused, or the payload is trusted) |
| K0106 | The signing key is not trusted by the host or any followed catalogue |
| K0107 | The signature does not verify |
| K0108 | The files on disk do not match the signed listing, or a path breaks the listing rules |
| K0109 | `plugin.json`'s id, version or publisher does not match the signature or the key |
| K0110 | The signing key is revoked by a followed catalogue |

Catalogue errors (`CatalogueError`):

| Code | Meaning |
|---|---|
| K0120 | No signature in `catalogue.sig` verifies under the current catalogue key |
| K0121 | The catalogue has expired (installs and updates refused) |
| K0122 | The catalogue's serial is lower than the stored one, or equal with different contents |
| K0123 | A downloaded artifact does not match its catalogue entry (`sha256` or `sigSha256`) |

`K0104` stays reserved for the interface hash (docs/69 §11).

## Rejected alternatives

- **Sigstore keyless signing** for v1 (Decision 2); kept possible through the
  `type` field.
- **NuGet and Maven signing**, and publishing plugins through the docs/39
  channels with a `kind = "plugin"` tag (Decisions 2 and 8).
- **A hosted Lyric plugin registry**: operational burden with no benefit over
  static catalogues for application-scoped plugins.
- **Per-platform crypto kernels**: the .NET BCL and Windows CNG lack Ed25519,
  so a pure-Lyric implementation would be needed anyway; one code path and
  one vector suite is simpler to audit.
- **A key chain in `plugin.sig`** for publisher rotation, and **threshold
  signatures** on catalogues: more format and verification surface than v1
  needs; catalogue-driven rotation covers both.
- **Blocking loads when a catalogue has expired**: breaks offline machines;
  the application is told instead (Decision 8).
