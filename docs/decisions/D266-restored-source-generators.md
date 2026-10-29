# D266 - Restored source generators: signed artifacts, pinned keys (D248 Decision 7, #8580)

**Status:** shipped. Implements D248 Decision 7; extends D150 and D207 (docs/40
§4.2 and §7, docs/38 §6, docs/39).

## Context

D248 Decision 7 said a source generator restored as a package carries
`plugin.sig`, and that `lyric.lock` pins the signer's key id on first resolve,
with a new key accepted only by `lyric restore --update <generator>`. Until
now the compiler took generators only from `path` and `workspace = true`
dependencies, which it builds from source; a registry or git generator was
X0009. Two questions were left open:

- `plugin.sig` names its key by id only (D248 Decision 4). Verifying it needs
  the public key, and D248 did not say where a consumer gets it.
- `lyric publish` packed only `lib/net10.0/<Pkg>.dll`, which a consumer
  links, and a git dependency is a source checkout.

## Decision

1. **A generator package carries its packed artifact.** A restored generator
   is never built from source. At the root of the restored package (the
   extracted `.nupkg`, or the git checkout or its `subdir`) it has:

   ```
   lyric-plugin/<id>-<version>/   the artifact `lyric plugin pack` writes, with plugin.sig
   lyric-plugin/signer.pub        the public key it is signed with
   ```

   A registry or git dependency whose package has `lyric-plugin/` is a
   source generator; `lyric-plugin/` must hold exactly one artifact
   directory. Any other registry or git dependency is a library, and
   `@generate` naming it is X0002.

2. **`lyric publish` of a generator.** For `[package] kind =
   "source-generator"`, `lyric publish` runs `lyric plugin pack` (dotnet
   payload), signs the artifact with `--sign-key <file>` or
   `LYRIC_PLUGIN_SIGNING_KEY` (required), writes `signer.pub`, and pushes a
   package holding only `lyric-plugin/`. It has no `lib/` assembly, so no
   consumer links it, and no NuGet dependencies, since the artifact carries
   everything the generator runs with; path dependencies are therefore
   allowed. It is tagged `lyric-source-generator`. A git generator commits
   the same `lyric-plugin/` layout (`lyric plugin pack --sign-key <key> -o
   lyric-plugin`, then the publisher's `.pub` as `lyric-plugin/signer.pub`).

3. **Where the key comes from: a pin, else trust on first use.** A dependency
   may pin the publisher key, `Gen = { version = "1.0.0", key =
   "lyric-ed25519:..." }` (registry and git dependencies only; on a path or
   workspace dependency it is a manifest error). The artifact must then be
   signed by that key. Without a pin, the key in `signer.pub` is trusted the
   first time the generator is restored. Either way the key's publisher name
   is the artifact's own `publisher`, so the pin is on the key alone.

4. **`lyric.lock` pins the key id.** `lyric restore` verifies the artifact
   (D248 Decision 6, steps 1-5; codes K0105-K0110) and records `key = "<key
   id>"` in the generator's `[[package]]` entry. A later restore that finds
   another key fails with a message naming both ids, until `lyric restore
   --update <name>` accepts it; the change shows in the lock file's diff.
   `--locked` fails on a changed key id like any other lock change, and
   refuses `--update`. `lyric update`, which re-resolves from scratch, carries
   the pinned key ids over and keeps the previous lock if a key changed, so it
   cannot accept a new key either. A build re-restores when a restored
   generator has no pinned key yet.

5. **Hosting through `discoverPlugins`.** When a build first runs a restored
   generator it is loaded with `Std.Plugin.discoverPlugins` from its
   `lyric-plugin/` directory, under a trust policy of the pinned keys alone,
   so its signature and every file are checked again at load (a changed file
   is K0108). Before that, the build checks that the key it would trust has
   the id `lyric.lock` pins (X0009 otherwise). Path and workspace generators
   are built from the project's own source and stay unsigned, registered as
   before.

## Diagnostics

No new codes. X0009 now covers a restored generator whose artifact fails
verification, whose key differs from the pinned one, or that `lyric.lock` has
no key for; X0002 covers a restored package without `lyric-plugin/`.

## Rejected alternatives

- **Requiring a pinned key**: safer against a compromised first download,
  but every consumer would copy a key by hand before trying a generator. The
  pin is available for those who want it, and the lock pins the key after
  the first restore either way.
- **Building restored generators from source**: needs the source and its
  dependencies, and an unsigned source checkout is the code D248 meant to
  verify.
- **Carrying the key inside the artifact**: it would sign itself; a key
  beside the artifact is the same trust-on-first-use, without listing the key
  in the signed files.
