# 22 — Distribution and Tooling

**Status:** Shipped (Stage 1 — D-progress-126 / D059; full AOT binary and
auto-update deferred to Phase 6+). Approved 2026-05-05 (PR #122 review follow-up).
**Implementation:** Stage 1 shipped: NuGet global tool (`dotnet tool install lyric`)
and standalone ZIP. AOT binary and channel-based auto-update are Phase 6+ work.
**Decision-log entry:** D059 (`docs/03-decision-log.md`).

## 1. Motivation

Today the bootstrap stdlib is consumed *from source*: the compiler
walks up from its binary directory looking for `lyric-stdlib/std/` and reads
the `.l` files at compile time. This works during compiler
development — every checkout has the source — but breaks the
"download a Lyric SDK and use it" story:

- A user installing `lyric` from a package manager (Homebrew,
  apt, scoop, the dotnet tool feed) does not get a `stdlib/`
  directory next to their binary unless we ship one explicitly.
- A `lyric build` of a user project recompiles every imported
  `Std.X` package from source on every cold run — fine for the
  bootstrap, slow as the stdlib grows.
- Reproducible builds across machines depend on every machine
  finding the *same* stdlib source at the same path.

This document specifies how the stdlib (and other built-in heads
like `Jvm.*` and `Lyric.*`) are distributed as **pre-compiled
binary artifacts** alongside the compiler, and how the compiler
finds them at runtime. It also covers the VS Code extension
features needed to make `lyric.toml` a first-class workflow.

## 2. Stdlib bundling

Once `docs/20-project-as-dll.md` ships, the stdlib becomes a
single-DLL project:

```toml
# stdlib/lyric.toml
[project]
name           = "Lyric.Stdlib"
output         = "single"
output_assembly = "Lyric.Stdlib.dll"

[project.packages]
"Std.Core"           = "std"
"Std.Collections"    = "std"
"Std.String"         = "std"
"Std.Math"           = "std"
"Std.Iter"           = "std"
"Std.File"           = "std"
"Std.Console"        = "std"
"Std.Errors"         = "std"
"Std.Parse"          = "std"
"Std.Time"           = "std"
"Std.Json"           = "std"
"Std.Http"           = "std"
"Std.Testing"        = "std"
# … etc, including kernels.
```

`lyric build` produces one `Lyric.Stdlib.dll` carrying every package's
`Lyric.Contract.<X>` resource. Downstream consumers `import Std.Core`
walk those resources to find the `Std.Core` surface, just as today
they walk `Lyric.Stdlib.Core.dll`'s single resource.

A single 3-5 MB DLL replaces the ~25 separately-cached
`Lyric.Stdlib.<X>.dll` files the bootstrap currently caches per-process
in `/tmp/lyric-stdlib-<pid>/`. Cold-build time drops by the cost of
~25 separate emit passes; downstream cache invalidation simplifies to
one file's mtime.

## 3. Compiler distribution layout

A standard `lyric` distribution looks like:

```
lyric/                          (install root, e.g. /usr/local/lib/lyric)
├── bin/
│   ├── lyric                   (CLI binary)
│   ├── lyric-lsp               (LSP server)
│   └── …
├── lib/
│   ├── Lyric.Stdlib.dll        (bundled stdlib per §2)
│   ├── Lyric.Stdlib.Json       (per-package contract metadata
│   │                            extracted as a sibling JSON file
│   │                            so `lyric doc` can render fast)
│   ├── lyric-resolver.jar      (bundled Maven resolver for JVM targets;
│   │                            see docs/31-maven-linking.md §3)
│   └── …
├── share/
│   └── stdlib/                 (optional source bundle for
│                                IDE go-to-definition / debugging)
└── version                     (semver of the SDK)
```

The runtime stdlib lookup in `Emitter.fs:locateBuiltinFile` extends
its search order:

1. Package-specific env-var override (today).
2. **NEW:** Walk the directory tree from `startDir` looking for
   `lib/Lyric.Stdlib.dll` — accept the binary artifact if found,
   skipping source compilation entirely.
3. Walk the directory tree looking for `lyric-stdlib/std/` source (today's
   path; remains the bootstrap-development fallback).

The binary path is preferred for installed builds; the source path is
preferred for `lyric` running inside its own source tree.
Discrimination is by which path resolves first.

## 4. Locating the SDK

When `lyric` is installed system-wide, the binary at
`/usr/local/bin/lyric` is typically a thin wrapper. The wrapper sets
`LYRIC_SDK_ROOT=/usr/local/lib/lyric` (or wherever the SDK was
installed) before invoking the real CLI. The CLI:

1. Honours `LYRIC_SDK_ROOT` if set.
2. Otherwise computes the SDK root from the CLI binary's path:
   `<binary>/../lib/Lyric.Stdlib.dll` is the typical layout.
3. Otherwise falls back to source-tree discovery.

`lyric --sdk-info` prints the resolved SDK root + stdlib path + version
for diagnostics.

## 5. Versioning

**Decision log:** D109 (Q-dist-007). **Status:** Shipped (PR #3960).

The compiler and stdlib carry a shared version file. `make lyric` writes
`sdk-version.json` into the stage-1 lib directory:

```json
{
  "language_version": "0.1",
  "stdlib_version": "0.1.0",
  "compiler_version": "0.1.0",
  "build_date": "2026-05-20T00:00:00Z"
}
```

`lyric version` prints all four fields and exits 0:

```
lyric 0.1.0  (language 0.1, stdlib 0.1.0, built 2026-05-20T00:00:00Z)
```

On every startup, `checkSdkVersion()` reads `sdk-version.json` from the
resolved lib directory and compares `compiler_version` to the binary's own
`VERSION()`. A mismatch prints a warning on stderr; setting
`LYRIC_STRICT_SDK_VERSION=1` promotes the warning to a fatal error (exits 1).
A missing `sdk-version.json` is silently ignored (dev-checkout and
non-SDK installs do not carry the file).

`lyric build` warns when the stdlib's `language_version` doesn't match
the source's `package` declaration (cross-compatibility check —
sources targeting an older language version against a newer stdlib are
fine; the reverse is a warning).

## 6. VS Code extension features

The existing extension (`lyric-vscode/`) provides syntax highlighting,
inline diagnostics, and basic LSP integration. Adding `lyric.toml`
management requires:

### 6.1 Manifest editor

A custom editor (or schema-backed JSON editor with TOML overlay) for
`lyric.toml` that:

- Auto-completes `[project]`, `[dependencies]`, `[nuget]`, etc.
- Validates against a JSON schema shipped with the extension.
- Underlines unknown package IDs, malformed semver, etc.
- Provides a "Add Lyric dependency" command that opens a
  package-search palette against the configured restore feed.

### 6.2 Package management commands

Command palette entries:

- **Lyric: Add dependency** — prompts for package id + version,
  appends to `[dependencies]`, runs `lyric restore` in the
  integrated terminal.
- **Lyric: Add NuGet package** — same but writes to `[nuget]`.
- **Lyric: Remove dependency** — list-pick from current entries.
- **Lyric: Update dependency** — bumps version; offers latest
  via the configured feed.
- **Lyric: Restore** — runs `lyric restore` and shows a progress
  notification.

### 6.3 Project navigator

A tree view alongside the file explorer showing:

- Project packages (with resolved per-package source paths).
- Restored Lyric dependencies (with version + contract-resource
  preview).
- Restored NuGet dependencies (with auto-generated shim files).

### 6.4 Build / run launch configurations

Pre-defined launch configurations in `.vscode/launch.json`:

- `Lyric: Build current project` (`lyric build`).
- `Lyric: Run` (`lyric run`).
- `Lyric: Test` (`lyric test`).
- `Lyric: Prove` (`lyric prove` against the current source file).

## 7. Migration

The bootstrap continues to walk for `lyric-stdlib/std/` as it does today —
no breaking change. An installed build prefers the binary stdlib but
retains source-tree fallback.

For users:

- New installs ship with `lib/Lyric.Stdlib.dll`; cold-build time drops
  immediately.
- Existing source-tree clones keep working.
- A user explicitly preferring source-built stdlib (e.g. for
  debugging) sets `LYRIC_STD_PATH` per the existing override.

## 8. Out of scope

- Online package registries beyond NuGet (e.g. a Lyric-native
  `crates.io`). Phase 6+.
- Cross-compilation / cross-SDK builds (e.g. running `lyric` from
  one machine to produce binaries for another). Phase 6+.
- Remote build caches. Future work.
- VS Code extension beyond the four feature blocks listed in §6.
  Anything else (debugging, refactoring, code lenses, semantic
  highlighting beyond the LSP basics) is its own design doc.

## 9. Diagnostic codes

| Code | Meaning |
|---|---|
| `B0040` | SDK root not found and `LYRIC_SDK_ROOT` unset; cannot locate stdlib |
| `B0041` | stdlib's `language_version` is newer than the source's declared version |
| `B0042` | stdlib DLL exists but `Lyric.SdkVersion` resource is missing or unreadable |

## 10. Open questions

- **Side-by-side SDK installs.** A team might run multiple Lyric
  language versions concurrently. The `LYRIC_SDK_ROOT` env-var
  handles single-active-version cleanly; multi-version requires a
  `lyric-toolchain` style pinned-per-project mechanism (rustup-like).
  Tracked as Q-toolchain-multiplexer; not in stage 1 scope.
- **Distribution channels.** Resolved in `docs/34-distribution-strategy.md`
  (D-progress-228 / D059): primary channel is `dotnet tool install lyric`
  (NuGet global tool); secondary is self-contained ZIP/tarball via GitHub
  releases; Homebrew/winget/apt deferred until the self-hosted AOT binary
  ships (Q-dist-001).  This document specifies the *layout* all channels
  conform to; doc 34 specifies the channels themselves.
