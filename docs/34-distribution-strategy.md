# docs/34-distribution-strategy.md — Compiler and stdlib distribution strategy

_Status: Drafted 2026-05-10 (D-progress-228)._
_Closes: open question "Distribution channels" in `docs/22-distribution-and-tooling.md` §10._
_Backing decision: D059 (see `docs/03-decision-log.md`)._

## 1. Overview

This document decides the distribution channels for the `lyric` compiler and
the `Lyric.Stdlib.dll` bundle, and describes the multi-stage bootstrap pipeline
that produces a self-hosted distribution from source.  It is the Phase 6
distribution-strategy decision referenced in `docs/22-distribution-and-tooling.md`.

The constraint is that the stage-0 compiler is the legacy F# bootstrap
under `bootstrap/src/Lyric.*/`.  Today's shipping user CLI is the AOT
entry-point binary `bootstrap/src/Lyric.Cli.Aot/` — a thin trampoline
into the Lyric-emitted `Lyric.Cli.Program.main` produced by stage 1.
The F# CLI (`Lyric.Cli`) only handles internal flags
(`--internal-build` and friends) used by the bootstrap pipeline.
The distribution strategy must work for the AOT trampoline today *and*
for a future fully native-AOT'd Lyric binary with no .NET SDK
dependency at runtime.

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

`dotnet build` the `Bootstrap.sln` solution in Release configuration.
This produces the legacy F# bootstrap compiler under
`bootstrap/src/Lyric.*/`, which handles the `--internal-*` flags
needed by stage 1 to compile `lyric-compiler/lyric/**/*.l` and the
stdlib bundle.  Stage 0 does **not** serve user CLI commands directly
(those flow through the AOT trampoline built in stage 1).

### Stage 1 — compile Lyric compiler packages

Using the stage-0 `lyric` binary with `--target dotnet-legacy` (F# emitter),
compile in dependency order:

1. `stdlib/` — `lyric build --manifest stdlib/lyric.toml` → `Lyric.Stdlib.dll`
2. Self-hosted lexer / AST / parser (`lyric-compiler/lyric/`)
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

**Source fallback (`lyric-stdlib/std/`)** — included in all distribution archives
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
  `LYRIC_STRICT_SDK_VERSION=1` is set.  (Designed; not yet
  implemented — tracked as Q-dist-007.)

Side-by-side SDK installs are handled by `LYRIC_SDK_ROOT`: setting it to an
absolute path overrides all search heuristics.  A `lyric-toolchain` multiplexer
(rustup-style) is deferred to Q-toolchain-multiplexer.

---

## 6. CI integration

The GitHub Actions workflow (`ci.yml`) runs after every push to `main`:

1. `dotnet build Bootstrap.sln` — F# compiler build.
2. `dotnet run --project tests/Lyric.Emitter.Tests` — full test suite.
3. `./scripts/bootstrap.sh --stage 1` — compile Lyric packages with the F#
   emitter.  Validates that all self-hosted source files compile cleanly.
4. (Nightly / pre-release only) `./scripts/bootstrap.sh --stage 2` — self-hosted
   recompile; `STRICT_VERIFY=1` once byte-for-byte parity is achieved.

---

## 7. Release workflow

Releases are published by pushing a version tag (e.g. `git tag v0.1.0 && git push
--tags`).  The `.github/workflows/publish.yml` workflow then:

1. **Builds self-contained binaries** for `linux-x64`, `linux-arm64`, `osx-arm64`,
   `osx-x64`, and `win-x64` using `dotnet publish --self-contained --runtime <RID>
   -p:PublishSingleFile=true`.
2. **Signs the Windows binary** with Authenticode via `AzureSignTool` if the
   `AZURE_KEY_VAULT_URL`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`,
   `AZURE_CLIENT_SECRET`, and `AZURE_CERT_NAME` repository secrets are set.
3. **Codesigns and notarizes the macOS arm64 binary** if `APPLE_TEAM_ID`,
   `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_DEVELOPER_CERT_BASE64`, and
   `APPLE_DEVELOPER_CERT_PASSWORD` secrets are set.  The `osx-x64` build is
   **not notarized** in the v1.0 workflow.  Apple Silicon Macs running
   Rosetta 2 should use the `osx-arm64` binary; Intel Mac users who download
   `osx-x64` will need to right-click → Open the first time to pass
   Gatekeeper, or run `xattr -d com.apple.quarantine lyric` after download.
   Full notarization for `osx-x64` is tracked as a future workflow enhancement.
4. **Packages** each binary into a `.tar.gz` (Linux / macOS) or `.zip` (Windows)
   archive named `lyric-<version>-<rid>.<ext>`.
5. **Uploads** all archives as GitHub Release assets.
6. **Packs** the NuGet global-tool package with `dotnet pack -p:PackAsTool=true`.
7. **Signs** the `.nupkg` with `dotnet nuget sign` if `NUGET_SIGNING_CERT_BASE64`
   and `NUGET_SIGNING_CERT_PASSWORD` secrets are set.
8. **Pushes** to NuGet.org using the `NUGET_API_KEY` secret.

### Required repository secrets

| Secret | Purpose |
|---|---|
| `NUGET_API_KEY` | NuGet.org API key for `dotnet nuget push` |
| `NUGET_SIGNING_CERT_BASE64` | Base64-encoded PFX for NuGet package signing |
| `NUGET_SIGNING_CERT_PASSWORD` | Password for the PFX |
| `AZURE_KEY_VAULT_URL` | Azure Key Vault URL for Authenticode signing |
| `AZURE_TENANT_ID` | Azure AD tenant for AzureSignTool |
| `AZURE_CLIENT_ID` | Service principal client ID |
| `AZURE_CLIENT_SECRET` | Service principal client secret |
| `AZURE_CERT_NAME` | Certificate name inside the vault |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_ID` | Apple ID email for notarytool |
| `APPLE_APP_PASSWORD` | App-specific password for notarytool |
| `APPLE_DEVELOPER_CERT_BASE64` | Base64-encoded Developer ID p12 certificate |
| `APPLE_DEVELOPER_CERT_PASSWORD` | Password for the p12 |
| `APPLE_DEVELOPER_ID` | "Developer ID Application: Name (TEAMID)" string |

Signing steps are silently skipped if the corresponding secrets are absent.  A
release without signing is valid for developer previews; production releases
targeted at enterprise deployments should have all secrets configured.

### Code-signing certificate fingerprint

_Record the SHA-256 fingerprint of the production signing certificates here once
they are issued:_

```
NuGet signing certificate (SHA-256): <pending — update when certificate issued>
Windows Authenticode (SHA-256):      <pending — update when certificate issued>
Apple Developer ID (SHA-1):          <pending — update when certificate issued>
```

---

## 8. Install script

`scripts/install.sh` is a zero-prerequisite POSIX installer (mirrors the
`rustup-init.sh` pattern).  It:

1. Detects platform and architecture (`uname -s` / `uname -m`).
2. Resolves the latest release version via the GitHub API (unless `--version`
   is passed).
3. Downloads the appropriate `.tar.gz` or `.zip` archive using `curl` or `wget`.
4. Extracts to `~/.lyric/bin` (or `--dir <path>`).
5. Adds the directory to the shell profile (`.bashrc`, `.zshrc`, or fish config)
   unless `--no-path` is passed.

```sh
# Install latest:
curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh | sh

# Install specific version:
curl -fsSL ... | sh -s -- --version 0.1.0

# Install to custom directory:
curl -fsSL ... | sh -s -- --dir /usr/local/bin
```

---

## 9. Library package registry

This document covers the distribution of the `lyric` compiler and stdlib. The
registry for third-party and first-party Lyric library packages (publish/restore
flows, NuGet.org as the .NET channel, GitHub Packages Maven as the JVM channel,
`lyric search`, lock-file checksums, private feeds) is specified separately in
`docs/39-package-registry.md` (D074).

---

## 10. Open questions

- **Q-dist-001** — AOT self-hosted binary path (§2.3): prerequisite is
  reproducible stage-2 bootstrap.  ETA: Phase 7.
  *Progress (#1494):* `bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj`
  now carries `<PublishAot>true</PublishAot>` + invariant globalization;
  `dotnet publish -r linux-x64` produces a self-contained native ELF
  `lyric` (~6 MB) that AOT-compiles the stage-1 Lyric-emitted compiler
  closure, and CI's `aot-smoke` job builds and runs a real example
  through it.  *Restored-dependency builds now work under the native
  binary (#3201):* the embedded contract-metadata read was migrated from
  `Assembly.Load(byte[])` to the metadata-direct reader
  (`Msil.MetadataReader`, pure byte reading of the PE/CLI metadata — no
  IL loader, AOT-safe), and `aot-smoke` exercises a restored-dependency
  build (the constdep/app const-inlining scenario) through the published
  native binary.  The native binary is therefore viable as a primary
  distribution channel rather than a dependency-free-only artifact.
- **Q-dist-002 / Q-dist-003 / Q-dist-004** — package manager formulas
  (Homebrew / winget / apt): deferred until Q-dist-001 resolves.
- **Q-dist-006** — Q-dist-005 resolved: `scripts/install.sh` ships as the
  zero-prerequisite path.  Q-dist-006 (signing) resolved: workflow and docs
  updated in D-progress-257.
