# D603 - `[package] targets` declares the backends a package supports (#9030)

**Status:** accepted; the manifest field and the local-dependency checks are shipped.

## Context

Backend-specific libraries (a JVM-only Quartz binding, a .NET-only Hangfire
binding) live in `nichobbs/lyric-ecosystem` (docs/71 phase 4, D552, D561). The
manifest had no way to say which backends such a package supports. The
alternatives were a runtime `NotImplemented` stub, which D552 removed from
public APIs, and a `feature = "jvm"` gate, which does not stop an application
from resolving the package for the wrong target.

## Decision

1. `[package] targets = [...]` is a non-empty array of distinct names from
   `"dotnet"`, `"jvm"` and `"native"`. Absent means all targets, so existing
   manifests are unchanged. Any other value is **F0053**.
2. `lyric build`, `lyric test` and `lyric run` of a manifest that excludes the
   requested `--target` fail before compiling with **F0054**.
3. The same commands fail with **F0055** when a path or workspace dependency,
   direct or transitive, excludes the target, naming the dependency chain.
4. Target names are strings in `PackageSection.targets`, not a union, so that
   a whole import of `Lyric.Manifest` does not introduce bare `Dotnet`/`Jvm`
   cases beside `Emitter.CompileTarget`'s.

## Not in this slice

Registry and git dependencies are not examined: their manifests are on disk
only after restore. Recording the field in the `.nuspec` (a `lyric-target-<t>`
tag), in contract metadata, and filtering `lyric search` and `lyric restore`
by it are tracked in the follow-up issue linked from #9030.

## Verification

`manifest_self_test`: absent, valid, each F0053 case. End to end: a package
with `targets = ["jvm"]` fails F0054 under `--target dotnet`, an application
depending on it fails F0055, and both build under `--target jvm`.
