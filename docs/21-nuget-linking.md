# 21 — NuGet Linking

**Status:** Drafted. Approved 2026-05-05 (PR #122 review).
**Implementation:** Phase 5 §M5.1 stage 2d (immediately after multi-file
packages + project-as-DLL, which closed in stage 2c.3 / D-progress-103).
The original draft slotted this for §M5.2; it was pulled forward to
2d once the multi-file infrastructure landed and the appetite for
arbitrary NuGet consumption arrived.
**Decision-log entry:** to follow on landing.

## 1. Motivation

Today a Lyric project can reach .NET surface in two ways:

1. **The audited extern boundary.** `extern type` + `@externTarget`
   declarations in `_kernel/` files name specific BCL types and
   methods. Every entry is hand-written and reviewed; the soft cap
   is currently 161, the hard cap 150 at v1.0. Suitable for the
   stdlib's curated edge.
2. **Restored Lyric packages.** `lyric.toml` `[dependencies]` pulls
   pre-compiled Lyric DLLs (each carrying a `Lyric.Contract` JSON
   resource) from a restore cache.

Neither path lets a Lyric project consume an arbitrary NuGet package.
A team that wants to use, say, `Npgsql`, `System.Text.Json`, or
`Polly` has to either fork those into hand-written `_kernel/` shims
(prohibitive) or do without (ditto).

This document specifies the discovery + restore + reference flow that
makes NuGet a first-class dependency source for Lyric projects, while
preserving the `@axiom` boundary that distinguishes trusted /
unverified code from ordinary Lyric code.

## 2. `lyric.toml` extensions

```toml
[nuget]
"Newtonsoft.Json"       = "13.0.3"
"System.Text.Json"      = "9.0.0"
"Npgsql"                = "8.0.0"

[nuget.options]
allow_native = false      # default: refuse packages with native deps
target       = "net10.0"  # default: project's target framework
```

| Field | Default | Meaning |
|---|---|---|
| `[nuget]` | empty | Map of package id → version. Same semantics as a csproj `<PackageReference>` block. |
| `allow_native` | `false` | If `true`, accept packages whose runtime requires native binaries (P/Invoke, unsafe code, etc.). Refused by default because they break the cross-platform shipping story. |
| `target` | project's target | TFM the restore evaluates against. Useful for testing pre-release-TFM packages. |

## 3. `lyric restore` flow

`lyric restore` already resolves Lyric-package binary dependencies.
Adding NuGet support extends the same command:

1. **Generate a transient csproj** in `target/restore/<projid>.csproj`
   listing every `[nuget]` entry as a `<PackageReference>` plus the
   project's TFM.
2. **Invoke `dotnet restore`** against that csproj. This produces
   a `target/restore/obj/project.assets.json` listing every
   resolved DLL + its dependency closure.
3. **Materialise** every resolved DLL into the project's restore
   cache (`target/restore/lib/`).
4. **Generate auto-shims** (§4) — one `_extern/<package>.l` per
   `[nuget]` entry — by reflecting on each DLL's public surface.
   Files are committed to the source tree so reviewers see the
   surface that will be in scope.

The bootstrap restore flow already speaks csproj for the Lyric-side
dependencies (see `Lyric.Cli/Pack.fs`); the NuGet flow piggybacks on
the same machinery.

## 4. Auto-generated extern shims

For each NuGet package, the shim generator emits a `_extern/<pkg>.l`
file like:

```
@axiom("from NuGet package System.Text.Json v9.0.0")
package SystemTextJson

extern type JsonSerializer = "System.Text.Json.JsonSerializer"
extern type JsonDocument   = "System.Text.Json.JsonDocument"

@externTarget("System.Text.Json.JsonSerializer.Serialize")
pub func serialize[T](value: in T): String = ()

@externTarget("System.Text.Json.JsonDocument.Parse")
pub func parse(json: in String): JsonDocument = ()

// … etc, surface enumerated by reflection …
```

Important properties:

- **Every generated package carries `@axiom("from NuGet package <id>
  v<ver>")`.** This is the single, mandatory annotation that
  distinguishes verified Lyric code from the unverified host
  surface. Hand-written `_kernel/*.l` files use the same scheme.
- **Files are committed to the source tree.** Auto-generation is
  idempotent and deterministic (sorted by name, locked to the
  package version), so check-in shows up in code review when a
  new dependency is added or upgraded.
- **The shim generator skips members that don't translate.**
  Skipped surface includes ref/`Span<T>` parameters, partially
  applied generics, unsafe types, and anything outside Lyric's
  type system. Skipped members are listed in `_extern/<pkg>.skip.md`
  with a short reason — visible in code review, easy to audit.
- **Where a NuGet symbol's name collides with a Lyric keyword**
  (e.g. a method named `match`), the generator suffixes it with
  `_` and emits a `// renamed to avoid keyword collision` comment.

## 5. Naming convention

A NuGet package id like `System.Text.Json` produces a Lyric package
named `SystemTextJson` (PascalCase, no dots). The mapping is
deterministic: drop dots, preserve casing, prepend a leading capital
if the package id is lowercase. The shim header documents the
original package id explicitly so the mapping is traceable.

Consumers `import SystemTextJson.{JsonSerializer, JsonDocument, parse}`.

## 6. Build pipeline integration

After `lyric restore`, the emitter's reference closure includes:

1. The audited stdlib DLLs (`Lyric.Stdlib.*.dll`).
2. The project's own DLL(s) per `docs/20-project-as-dll.md`.
3. Every NuGet DLL materialised in `target/restore/lib/`.

The bootstrap emitter already resolves arbitrary CLR types via
reflection-driven FFI (see `docs/10-bootstrap-progress.md`
D-progress-026, D-progress-061). The new work is the *registration*
path — adding NuGet DLLs to the `Assembly.LoadFrom` set the emitter
walks during type resolution.

At runtime, `dotnet exec <out>` finds NuGet DLLs through the standard
.deps.json mechanism. `lyric build` writes the project's `.deps.json`
to include every transitive NuGet DLL, mirroring what `dotnet
publish` does for csproj builds.

## 7. AOT compatibility

The language reference §11.3 promises that "all Lyric code is
AOT-compatible." That promise has always covered code Lyric *itself*
emits. NuGet packages are out-of-scope: many depend on reflection,
runtime codegen, or P/Invoke that AOT compilers reject (or trim
unsoundly).

We adopt the .NET tooling's own enforcement model rather than adding
Lyric-level policy:

- `lyric build` emits ordinary IL targeting the project's TFM.
- `dotnet publish -p:PublishAot=true` runs the AOT compiler against
  the emitted assembly + its NuGet closure. Trim warnings + AOT
  errors surface there, in standard .NET form.
- The lyric-tool side does **not** maintain an "AOT-safe NuGet
  allowlist" or pre-flight the .NET tooling's analysis. That would
  duplicate work .NET does well and ages poorly as packages are
  upgraded.

**Caveat documented:** projects with `[nuget]` entries forfeit the
"all Lyric code AOT-compatible" guarantee — silently when the trim
result is a runnable-but-broken binary, loudly when AOT errors out.
Teams that need AOT should either avoid NuGet or audit each NuGet
dep against the AOT-safe-NuGet criteria the .NET docs publish.

## 8. Security / supply-chain

NuGet packages execute their own MSBuild targets at restore time and
their own IL at runtime. Adding NuGet to a Lyric project inherits the
.NET supply-chain trust model wholesale.

Mitigations Lyric tooling adds on top:

- **Generated shim is a code-review artefact.** Reviewers see a
  diff of the public surface every time a NuGet dep is added or
  upgraded. Symbols added by upstream that cross the package
  boundary are visible.
- **`@axiom("from NuGet package <id> v<ver>")`** appears verbatim
  in every contract resource. `lyric public-api-diff` lists axiom
  changes (a removed axiom is a SemVer-major event). Downstream
  consumers see exactly which NuGet packages a published Lyric DLL
  trusts.
- **No transitive `@axiom` re-export.** A Lyric package that consumes
  `SystemTextJson` does not transitively re-axiom-vouch for it; the
  trust is local. (Same rule as today for `_kernel/` packages.)

Out of scope: cryptographic verification of restored NuGet packages
beyond what `dotnet restore` provides. Future work tracks under
`docs/06-open-questions.md` Q-nuget-supply-chain.

## 9. Migration path

Existing projects continue to work with no changes. Adding a NuGet
dep is opt-in:

```toml
[nuget]
"Polly" = "8.0.0"
```

Then `lyric restore`, then `import Polly.{…}` in source.

Removing a NuGet dep is the inverse: drop the entry, `lyric restore`,
delete the auto-shim file (or let the next restore prune it).

## 10. Diagnostic codes

| Code | Meaning |
|---|---|
| `B0030` | NuGet package failed to restore (network / not-found / TFM mismatch) |
| `B0031` | NuGet package requires native binaries; `allow_native = false` |
| `B0032` | NuGet package member skipped during shim generation (type-mapping failure) — informational, not an error |
| `B0033` | hand-edited auto-shim drifted from generated form; re-run `lyric restore` |

## 11. Out of scope

- Direct reference to a `.dll` on disk (`<Reference Include="…">`).
  Always go through NuGet or the Lyric-package restore flow so the
  audit story is preserved.
- Source-level NuGet (a NuGet package whose contents are `.l` files).
  Lyric source distribution is via `lyric publish`, not NuGet.
- NuGet packages declared in `lyric.toml` referencing pre-release
  feeds, custom feeds, or auth-required feeds. Stage 1 ships the
  default nuget.org feed only; alternate feeds are a Phase 6
  follow-up.
- Implicit transitive imports. A NuGet package's transitive deps
  are restored, but they don't get auto-shims unless the user
  declares them explicitly. Reasoning: keeps the auditable
  `@axiom` boundary aligned with what the user wrote in
  `lyric.toml`.
