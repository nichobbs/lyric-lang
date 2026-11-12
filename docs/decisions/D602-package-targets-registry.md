# D602 - Registry, git and single-file enforcement of `[package] targets` (#9031)

**Status:** shipped. Completes D601.

## Decision

1. **Tags carry the targets in the registry.** `lyric publish` adds one
   `lyric-target-<t>` tag per supported target to the `.nuspec`, next to
   `lyric-package`. A package that declares no `targets` is tagged with all
   three, so a tag filter never hides it. A package published before this has
   no `lyric-target-*` tag and is taken to support every target.
2. **Restored dependencies are checked (F0055).** A registry dependency is read
   from the tags of the `.nuspec` NuGet extracts beside its DLL (a registry
   package ships no `lyric.toml`); a git dependency from the checkout's
   `lyric.toml`. `lyric restore --target <t>` checks after restoring, and
   `targetSupportError` checks restored dependencies on every build, test and
   run, so a lock that is already current is checked too.
3. **`lyric search <term> --target <t>`** keeps results whose tags include the
   target, or that have no target tags, from the first 100 results.
4. **Single-file builds** that find or are given a manifest apply F0054 to it
   (dotnet, jvm and native).
5. **No `targets` key in contract metadata.** The issue proposed one so a
   restored dependency could be checked without its manifest. The tags and the
   manifest already cover every source of a restored package; a third copy
   inside the DLL would be one more place for the declared targets to drift.

## Limits

- The registry check happens after the package is downloaded, not before:
  NuGet extracts it during `dotnet restore`. The build still stops before
  compiling.
- Only the dependencies the root manifest declares are checked. A registry
  package's own Lyric dependencies are resolved by NuGet from its
  `<dependencies>`, which carry no target information.

## Verification

`manifest_self_test`: tag generation, tag parsing, `nuspecTags`.
`cli_publish_self_test`: the nuspec tags and `searchResultTags`. End to end:
a git dependency and a fake restored registry package.
