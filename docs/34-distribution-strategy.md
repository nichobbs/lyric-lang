# docs/34-distribution-strategy.md — Compiler and stdlib distribution strategy

_Status: Drafted 2026-05-10 (D-progress-228)._
_Closes: open question "Distribution channels" in `docs/22-distribution-and-tooling.md` §10._
_Backing decision: D059 (see `docs/03-decision-log.md`)._

## 1. Overview

This document decides the distribution channels for the `lyric` compiler and
the `Lyric.Stdlib.dll` bundle, and describes the multi-stage bootstrap pipeline
that produces a self-hosted distribution from source.  It is the Phase 6
distribution-strategy decision referenced in `docs/22-distribution-and-tooling.md`.

The constraint is that the bootstrap compiler is an F# program.  The distribution
strategy must work for today's F#-hosted binary *and* for a future self-hosted
binary that has no F# or .NET SDK dependency.

---

## 2. Channels

### 2.1 Primary: `dotnet tool install lyric` (NuGet global tool)

The initial distribution channel is a .NET global tool published to NuGet.org.
This is the lowest-effort route to a cross-platform `lyric` binary: users with
the .NET SDK already installed run one command.

```
dotnet tool install -g lyric
```

The NuGet package (`Lyric.Cli` / package ID `lyric`) contains:

```
tools/
  net10.0/
    any/
      lyric.dll            # the CLI entry point
      Lyric.Lexer.dll
      Lyric.Parser.dll
      Lyric.TypeChecker.dll
      Lyric.Emitter.dll
      Lyric.Verifier.dll
      Mono.Cecil.dll
      System.Reflection.MetadataLoadContext.dll
lib/
  Lyric.Stdlib.dll         # pre-compiled stdlib bundle (dotnet target)
  Lyric.Stdlib.Jvm.jar     # pre-compiled stdlib bundle (JVM target)
stdlib/
  std/                     # stdlib Lyric source (fallback for cold-cache builds)
  lyric.toml
```

The `lib/` and `stdlib/` content conforms to the SDK layout in
`docs/22-distribution-and-tooling.md` §3.  The tool finds `lib/Lyric.Stdlib.dll`
via the `LYRIC_SDK_ROOT` path or by walking up from the `lyric.dll` location.

**Why NuGet global tool first?**

- Works on Windows, macOS, and Linux without a package-manager middleman.
- CI agents with the .NET SDK (GitHub Actions `setup-dotnet`, Azure Pipelines)
  get `lyric` in one step.
- NuGet signing + reproducible builds are already wired through the Lyric CI.
- The F# / dotnet-tool packaging path is well-understood; no new infrastructure.

### 2.2 Secondary: standalone ZIP / tarball

For environments without the .NET SDK (or where installing it is impractical),
a standalone self-contained `lyric` binary is published alongside the NuGet
package as a GitHub release asset.

The self-contained binary is produced by `dotnet publish --self-contained true
--runtime <RID>` which bundles the .NET runtime into the output directory.
Platform-specific release assets:

| Asset | RID |
|---|---|
| `lyric-linux-x64.tar.gz` | `linux-x64` |
| `lyric-linux-arm64.tar.gz` | `linux-arm64` |
| `lyric-osx-x64.tar.gz` | `osx-x64` |
| `lyric-osx-arm64.tar.gz` | `osx-arm64` |
| `lyric-win-x64.zip` | `win-x64` |

Each archive contains the same `lib/` and `stdlib/` layout as the NuGet tool.
The archive root contains a `lyric` (or `lyric.exe`) native binary — no
`dotnet` command needed.

### 2.3 Future: self-hosted binary (no .NET dependency)

Once the self-hosted MSIL emitter can reproducibly compile the full compiler
pipeline (stage-2 bootstrap in `scripts/bootstrap.sh`), the distribution can
switch to a self-hosted binary with no .NET runtime requirement.

The path to get there:

1. `scripts/bootstrap.sh --stage 2` produces stage-2 DLLs that are
   byte-for-byte identical to stage-1 DLLs (reproducible bootstrap).
2. The stage-2 `Msil.Bridge.dll` is promoted to the canonical compiler DLL
   and the F# emitter is demoted to `--target dotnet-legacy`.
3. An AOT compile step (`dotnet publish --aot`) produces a native binary
   from the self-hosted compiler DLLs; this binary has no .NET SDK dependency.
4. The NuGet tool and ZIP archives are rebuilt from the AOT binary.

This is tracked as a Phase 7 deliverable (Q-dist-001).

### 2.4 Package managers (Homebrew, winget, apt) — deferred

Platform package managers add discoverability but require maintenance of
tap/formula/package-spec files outside this repository.  Deferred until the
self-hosted binary path (§2.3) ships — at that point the binary is a
self-contained native executable and the formula is trivial.

Tracked as Q-dist-002 (Homebrew), Q-dist-003 (winget), Q-dist-004 (apt/deb).

---

## 3. Bootstrap pipeline

The three-stage bootstrap lives in `scripts/bootstrap.sh`:

```
Stage 0 → F# bootstrap compiler (lyric-stage0)
Stage 1 → compile Lyric compiler sources with stage-0  (lyric-stage1 DLLs)
Stage 2 → recompile with stage-1 self-hosted MSIL emitter (lyric-stage2 DLLs)
           compare stage-1 and stage-2 DLLs for byte-for-byte identity
```

### Stage 0 — F# bootstrap

`dotnet publish` the `Lyric.Cli` project in Release configuration.  The output
is a platform-native `lyric` binary (with embedded .NET runtime if `--self-
contained true`).  This is the current shipping binary.

### Stage 1 — compile Lyric compiler packages

Using the stage-0 `lyric` binary with `--target dotnet-legacy` (F# emitter),
compile in dependency order:

1. `stdlib/` — `lyric build --manifest stdlib/lyric.toml` → `Lyric.Stdlib.dll`
2. Self-hosted lexer / AST / parser (`compiler/lyric/lyric/`)
3. Self-hosted type checker, mode checker, contract elaborator
4. Self-hosted test synth
5. MSIL binary layer: heaps → tables → opcodes → PE → assembler
6. MSIL high-level layer: lowering → codegen → bridge

The output is a set of DLLs in `.bootstrap/stage1/`.  The stage-0 `lyric`
binary can now load `Msil.Bridge.dll` via `SelfHostedMsil` reflection and
route `--target dotnet` through the self-hosted MSIL pipeline.

### Stage 2 — self-hosted recompile (reproducibility check)

Using the same stage-0 `lyric` binary but with `LYRIC_STD_PATH` pointing at
stage-1 DLLs, recompile all stage-1 source files with `--target dotnet`
(self-hosted MSIL path).  Store output in `.bootstrap/stage2/`.

Compare stage-1 and stage-2 DLLs with `cmp -s`.  A match means the self-hosted
emitter produces identical output to the F# emitter — the bootstrap is
reproducible.  Mismatches are expected during stabilisation; set `STRICT_VERIFY=1`
to fail the script on any diff.

### Running the bootstrap

```sh
# Full three-stage bootstrap with reproducibility check:
./scripts/bootstrap.sh

# Build F# compiler and compile Lyric packages only (no self-hosted recompile):
./scripts/bootstrap.sh --stage 1

# Skip byte-for-byte comparison:
SKIP_VERIFY=1 ./scripts/bootstrap.sh

# Fail on any diff (CI gate for the reproducible-bootstrap milestone):
STRICT_VERIFY=1 ./scripts/bootstrap.sh
```

---

## 4. Stdlib distribution

The stdlib is distributed in two forms:

**Pre-compiled bundle (`lib/Lyric.Stdlib.dll`)** — produced by
`lyric build --manifest stdlib/lyric.toml --target dotnet`.  This is what
installed builds use; `lyric build` finds it via `LYRIC_SDK_ROOT/lib/`
or by walking up from the binary location.  Cold-build time is eliminated
because stdlib packages are loaded from DLL rather than recompiled from source.

**Source fallback (`stdlib/std/`)** — included in all distribution archives
as a fallback.  If `lib/Lyric.Stdlib.dll` is absent or the version resource
does not match the compiler version, the compiler falls back to source and
recompiles the stdlib package it needs.  This ensures out-of-tree builds (e.g.
a developer cloning the repo) always work.

The JVM stdlib bundle (`Lyric.Stdlib.Jvm.jar`) is produced by
`lyric build --manifest stdlib/lyric.toml --target jvm` and shipped alongside
`Lyric.Stdlib.dll` in the NuGet tool's `lib/` directory.

---

## 5. Version pinning

The NuGet tool package version matches the Lyric language version (`0.1.0`,
`0.2.0`, etc.).  `lib/Lyric.Stdlib.dll` carries a `Lyric.SdkVersion`
embedded resource containing the same version string.  The compiler checks
this at startup:

- **Match** — use the pre-compiled stdlib DLL.
- **Mismatch** — warn and fall back to source stdlib, or error if
  `LYRIC_STRICT_SDK_VERSION=1` is set.

Side-by-side SDK installs are handled by `LYRIC_SDK_ROOT`: setting it to an
absolute path overrides all search heuristics.  A `lyric-toolchain` multiplexer
(rustup-style) is deferred to Q-toolchain-multiplexer.

---

## 6. CI integration

The GitHub Actions workflow (`ci.yml`) runs after every push to `main`:

1. `dotnet build Lyric.sln` — F# compiler build.
2. `dotnet run --project tests/Lyric.Emitter.Tests` — full test suite.
3. `./scripts/bootstrap.sh --stage 1` — compile Lyric packages with the F#
   emitter.  Validates that all self-hosted source files compile cleanly.
4. (Nightly / pre-release only) `./scripts/bootstrap.sh --stage 2` — self-hosted
   recompile; `STRICT_VERIFY=1` once byte-for-byte parity is achieved.

---

## 7. Open questions

- **Q-dist-001** — AOT self-hosted binary path (§2.3): prerequisite is
  reproducible stage-2 bootstrap.  ETA: Phase 7.
- **Q-dist-002 / Q-dist-003 / Q-dist-004** — package manager formulas
  (Homebrew / winget / apt): deferred until Q-dist-001 resolves.
- **Q-dist-005** — installer UX: should `dotnet tool install` be the
  recommended install path, or should a `curl | sh` installer script be
  provided as the zero-prerequisite path (installs .NET SDK and then lyric)?
- **Q-dist-006** — signing: NuGet package signing and binary code-signing
  (Windows Authenticode, macOS notarisation) requirements for enterprise
  deployments.
