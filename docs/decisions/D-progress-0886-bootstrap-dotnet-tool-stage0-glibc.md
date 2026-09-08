# D-progress-886 — Stage-0 acquisition can use the NuGet global tool to dodge a GLIBC floor (#7043)

**Status:** shipped

## Context

`build-stage2` started running on the self-hosted `CI_HEAVY_RUNNER` pool as of
D-progress-885's PR (#7036), to match the architecture of its consumer
(`compiler-self-tests-jvm`). Its first real run there failed immediately in
`scripts/bootstrap.sh`'s Stage 0 — before touching anything #7036 changed —
with:

```
.bootstrap/stage0-publish/lyric: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
```

`readelf -V` against every published `lyric-*-linux-arm64.tar.gz` release
back to v0.4.13 confirms this isn't a bad release to pin around: every one of
them requires `GLIBC_2.34`, because `publish.yml`'s `build-standalone` job
cross-compiles the Native AOT ARM64 binary on `ubuntu-latest`, whose glibc has
been ahead of the self-hosted runner's the entire time. Native AOT links the
build machine's own glibc symbol versions directly into the binary, so this
floor tracks whatever `ubuntu-latest` happens to be, not anything the release
process pins deliberately.

## Decision

Give `scripts/bootstrap.sh`'s Stage 0 a second, opt-in acquisition path: when
`LYRIC_BOOTSTRAP_USE_DOTNET_TOOL=1` and the platform is `linux-x64` or
`linux-arm64`, install the published `lyric` NuGet global tool
(`docs/34-distribution-strategy.md`'s existing "NuGet global tool" channel,
already shipped via `publish.yml`'s `publish-nuget` job) into
`stage0-publish/` instead of downloading the native release tarball.

This works because the tool's apphost shim is a *different* artifact than the
release tarball's Native AOT binary: it's Microsoft's own portable native
launcher (verified via `readelf -V`: GLIBC floor ~2.16, universally available),
which execs into the managed `Lyric.Lyric.Cli.dll` via whatever `dotnet`
runtime is already installed on the machine — the same runtime the
`dotnet lyric.dll`-wrapper jobs (#7025/#7026) already run fine on this exact
self-hosted pool. Confirmed locally end-to-end: `LYRIC_BOOTSTRAP_USE_DOTNET_TOOL=1
./scripts/bootstrap.sh --stage 1` genuinely compiles the stdlib bundle through
the tool-acquired stage-0 binary.

`ci.yml`'s `build-stage2` job now sets `LYRIC_BOOTSTRAP_USE_DOTNET_TOOL` to
`1` only when `runner.environment == 'self-hosted'`; GitHub-hosted
`ubuntu-latest` keeps the native-download path unchanged, since it has no
glibc-floor problem.

## Scope and follow-ups

This is deliberately the minimal fix that unblocks CI now, not the release
pipeline's own portability. Left open, tracked in #7043:

- Making the fallback automatic (detect the dynamic-linker failure and retry
  via the tool path) instead of requiring the explicit env var, generalizing
  the self-healing idiom #7026 established for the wrapper script.
- The broader ecosystem-portability question: whether `publish.yml` should
  build the `linux-arm64` *release* itself against an older glibc baseline
  (or `linux-musl-arm64`, fully static) so real end users on older-glibc
  distros don't hit the same wall the self-hosted runner did. That is release
  infrastructure, needs its own validation on real hardware, and is out of
  scope for unblocking CI.
