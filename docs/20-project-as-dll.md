# 20 — Project-as-DLL Bundling

**Status:** Drafted. Approved 2026-05-05 (PR #122 review).
**Implementation:** Phase 5 §M5.2 (post-multi-file-packages).
**Decision-log entry:** to follow on landing.

## 1. Motivation

Today every Lyric package compiles to its own DLL. A project with
five packages produces five DLLs, even when they all ship together as
one application binary. Each cross-package call inside the project
round-trips through the binary `Lyric.Contract` JSON resource the
emitter embeds in each DLL — at compile time, not runtime, but still
work that's redundant when both ends of the call are in the same
project.

This document specifies how a Lyric *project* (a set of related
packages declared by one `lyric.toml`) compiles to a single DLL while
preserving package boundaries as namespaces and contract resources.

Multi-file packages (one package, multiple `.l` files) is a
prerequisite shipped per `docs/19-multi-file-packages.md`.

## 2. The `internal` visibility tier

Lyric today has two tiers: package-private (default) and `pub`. With
project-as-DLL bundling, packages within the same project routinely
need to call each other without exposing the call to downstream
consumers. The current options are inadequate:

- Use `pub` for the cross-package call → leaks the symbol to
  consumers of the published DLL.
- Stay package-private → blocks the call.

Adding an `internal` tier resolves the bind:

```
pub func widelyVisible(): Int = …             // visible to consumers
internal func projectVisible(): Int = …       // visible to other packages
                                              //   in the same project
func packagePrivate(): Int = …                // visible only inside
                                              //   this package
```

Lowering on .NET: `pub` → `public`, `internal` → `assembly`
(`internal` in C# terms), package-private → `private` plus
package-name-mangled access via package-internal helpers (existing
behaviour).

The contract-metadata resource includes only `pub` declarations. An
`internal` symbol is *invisible* to the contract walker — downstream
consumers of the published DLL cannot see it, name it, or call it.
Enforcement is dual-layer: at the Lyric type-check level (no import of
an `internal` symbol from a different project) and at the .NET level
(the IL emits with `assembly` access modifier, so even reflection is
blocked across DLL boundaries).

`internal` is added to the §1.5 reserved keyword list. Soft-keyword
deferral is rejected: cross-project enforcement requires the type
checker to recognise the marker unambiguously without context.

## 3. `lyric.toml` extensions

```toml
[project]
name           = "MyApp"
output         = "single"            # "single" (default) | "per-package"
output_assembly = "MyApp.dll"        # only when output = "single"

[project.packages]
# Optional explicit list; defaults to glob `<src_root>/**/<package>/`.
"MyApp.Core"   = "src/core"
"MyApp.Db"     = "src/db"
"MyApp.Web"    = "src/web"
```

| Field | Default | Meaning |
|---|---|---|
| `output` | `"single"` | Bundle every package in `[project.packages]` into one DLL. `"per-package"` retains the current N-DLLs-per-project shape. |
| `output_assembly` | `<name>.dll` | Output filename for `output = "single"`. |
| `[project.packages]` | (auto-discover) | Optional explicit map from package name to source directory. Empty = walk the source root for every directory containing `.l` files. |

`output = "per-package"` is kept as an escape hatch for libraries that
want each package independently consumable as its own DLL — the same
shape the bootstrap stdlib uses today. `output = "single"` is the
new default for application projects.

### 3.1 Local-path dependencies

A `[dependencies]` entry may use the inline-table `{ path = "..." }` form to
reference another Lyric project on the local file-system:

```toml
[dependencies]
"Lyric.Web"    = { path = "../lyric-web" }
"Lyric.Stdlib" = { path = "../lyric-stdlib" }
```

**Semantics:**

- The path is relative to the directory containing the `lyric.toml` that
  declares it.
- The dependency's own `lyric.toml` is read to discover its
  `[project].output_assembly` (or the default `<name>.dll`).
- The resolved DLL must already exist at `<dep-dir>/bin/<assembly>.dll`.
  `lyric build` does **not** rebuild dependencies automatically; build them
  first with `lyric build --manifest <dep>/lyric.toml`.
- The resolved DLL path is passed to the compiler as a restored reference,
  making the dependency's public types and functions available during
  type-checking and code generation.

**Constraints:**

- Only local-path deps built with `output = "single"` produce a single DLL
  that can be wired this way. Per-package builds produce multiple DLLs and
  are not yet supported here.
- Circular local-path dependencies are not detected at the manifest level;
  avoid them.
- The `path` form and the registry/NuGet forms are mutually exclusive for a
  given package name within one `[dependencies]` block.

## 4. Compilation pipeline

The `output = "single"` driver:

1. **Discover** every package declared by `[project.packages]` (or
   the glob default).
2. **Topologically sort** packages by intra-project import order.
   Cycles raise `B0020 — circular intra-project package dependency`.
3. **Compile each package** as today (lex / parse / merged
   multi-file-package symbol table / type-check), but defer codegen
   into one shared `PersistedAssemblyBuilder`.
4. **Emit each package** into one DLL with one `<TopLevelType>`
   per package, namespaced under the package name. The top-level
   `Program` type holds the entry-point `main` (one `pub func main`
   in the project — multiple is `B0021`).
5. **Embed one contract resource per package**: the published DLL
   carries `Lyric.Contract.MyApp.Core`, `Lyric.Contract.MyApp.Db`,
   etc. Downstream consumers walking the resources see every public
   package surface.
6. **Mark internal-only packages** with an `Internal = true` flag in
   the resource; the contract walker hides them from `import`
   resolution outside the project.

Cross-package calls within the project skip the contract-metadata
round-trip and resolve through the in-process symbol table directly,
since both ends are visible to the emitter at the same time.

## 5. `lyric publish`

`lyric publish` for `output = "single"` ships the project as one DLL
with all per-package contract resources baked in. Consumers reach
public packages via `import MyApp.Core.{X}` etc. Internal packages
are unreachable.

For `output = "per-package"`, `lyric publish` retains today's
behaviour: one DLL per package, each with its own contract resource.

### 5.1 Bundling the stdlib

The canonical use case for `output = "single"` is the bootstrap
stdlib itself. Today every `Std.X` precompiles to its own
`Lyric.Stdlib.X.dll` (~25 separate DLLs cached per-process in
`/tmp/lyric-stdlib-<pid>/`). With this design, the stdlib becomes one
project shipping one `Lyric.Stdlib.dll` carrying every `Std.X`'s
contract resource side-by-side. Cold-build time drops by the cost of
~25 separate emit passes; `lyric` distributions ship a single
artifact. See `docs/22-distribution-and-tooling.md` §2 for the
concrete `lyric-stdlib/lyric.toml` and §3 for the SDK install layout the
bundled stdlib lives in.

## 6. Migration path

Existing packages continue to work in `per-package` mode without
changes. Adopting `single` mode is opt-in via `lyric.toml`:

```toml
[project]
output = "single"
```

The bootstrap stdlib stays in `per-package` mode (each `Std.X` is
independently consumable). The self-hosted compiler — once it has
multiple internal packages — adopts `single`.

## 7. Output-filename / assembly-name convention

When `output = "single"` and `output_assembly` is unset, the assembly
name is the project's `name` field (PascalCase) plus `.dll`.
`lyric-compiler/lyric/` would become `Lyric.dll` containing
`Lyric.Lexer` (and eventually `Lyric.Parser`, `Lyric.TypeChecker`,
…) all in one DLL.

## 8. Reflection / diagnostic story

A stack frame in a project-as-DLL build reports the fully-qualified
type name (`MyApp.Core.Foo`) the same way C# does today. Stack traces
are unchanged.

`lyric doc` reads every per-package contract resource separately and
emits one HTML / JSON tree per package, regardless of physical DLL
layout.

`lyric public-api-diff` operates per-package — a published project
DLL is compared against another by walking each package resource
pair-wise.

## 9. Out of scope

- Mixed-mode projects (some packages `single`, others `per-package`).
  All-or-nothing per project.
- Source-level package merging (collapsing two packages into one).
  Multi-file packages already cover the legitimate case.
- Whole-program optimisations (devirtualisation, cross-package
  inlining). Possible later, not part of this design.

## 10. Diagnostic codes

| Code | Meaning |
|---|---|
| `B0020` | circular intra-project package dependency |
| `B0021` | multiple `pub func main` declarations in `output = "single"` project |
| `B0022` | `internal` symbol referenced from outside the project |
| `B0023` | `output = "single"` project has zero discovered packages |

## 11. Open questions

- **Should `internal` be transitive across re-exports?** A package
  that does `pub use Foo.Internal.bar` in `output = "single"` mode
  is silently leaking. The lint already warns on this for `pub
  use`; should it harden to an error in single-output mode?
  Tracked as Q-internal-reexport-soundness.
