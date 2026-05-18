# 38 — Workspace, Git Dependencies, and Local Library Resolution

**Status:** Specced in D073. Open questions Q-W-001 through Q-W-004 (native dep
elimination) remain unresolved.

---

## 1. Problem

The ecosystem libraries (`lyric-cache`, `lyric-web`, `lyric-grpc`, etc.) live
in the same repository as the compiler and stdlib. At present:

- In-repo cross-library deps use `path = "../lyric-cache"`, which works inside
  the monorepo but is meaningless for external consumers who install from a
  registry.
- `[nuget]` and `[maven]` entries appear in every library that wraps a native
  package; application developers who consume these libraries currently have no
  principled way to avoid repeating those entries.
- There is no mechanism for consuming an external Lyric package that has not yet
  been published to a registry.

This sketch specifies three orthogonal features — workspace-local resolution,
git-source dependencies, and transitive native dep propagation — that together
address these problems. It also sketches a path toward eliminating `[nuget]` /
`[maven]` from application manifests entirely (open questions Q-W-001–Q-W-004).

---

## 2. Workspace

### 2.1 Root manifest

A workspace is declared by adding a `[workspace]` table to a `lyric.toml` at
the repository root. The root manifest has no `[package]` section (a "virtual
workspace"):

```toml
# lyric.toml — workspace root

[workspace]
exclude = [
  "scratch",
  "examples/experimental",
]
```

The toolchain identifies a workspace root by walking up from the current working
directory until it finds a `lyric.toml` containing a `[workspace]` table (the
same root-finding algorithm Cargo uses). If no workspace root exists, the
project is standalone and workspace features are not available.

### 2.2 Member discovery

Members are discovered automatically. The toolchain walks all subdirectories of
the workspace root (depth-first, following symlinks once) and collects every
directory that contains a `lyric.toml`. Directories whose root-relative path
matches any entry in `exclude` — or whose `lyric.toml` contains
`workspace = false` in its `[package]` table — are skipped, along with their
descendants.

```toml
# lyric-scratch/lyric.toml — excluded from the workspace
[package]
name        = "Lyric.Scratch"
version     = "0.0.1"
workspace   = false
```

The workspace does not require members to be listed explicitly. The exclusion
list is the only maintenance burden.

### 2.3 Member index

After discovery the toolchain builds an in-memory index:

```
package-name → absolute directory path
```

This index is used by the resolver when a dependency declares
`{ workspace = true }` (§3.1).

---

## 3. Dependency forms

The `[dependencies]` table in a `lyric.toml` gains three source forms in
addition to the existing `{ path = "..." }` form (which remains valid for
non-workspace projects and is accepted inside workspaces too, with a consistency
check):

### 3.1 Workspace form

```toml
[dependencies]
"Lyric.Cache"    = { workspace = true }
"Lyric.Stdlib"   = { workspace = true }
```

The toolchain looks up the package name in the workspace index and resolves the
dependency to that member's directory. If the name is not found in the index,
the build fails with a clear diagnostic:

```
error: 'Lyric.Cache' declared as workspace = true but no workspace member
       with that name was discovered.
       Hint: check [workspace].exclude in the root lyric.toml, or add
       workspace = false to the member's [package] table to investigate.
```

**Optional version constraint.** A `version` key can be added to assert that
the workspace member's declared version satisfies a semver constraint. This is
useful for catching accidental version skew within the monorepo:

```toml
"Lyric.Cache" = { workspace = true, version = "0.1.0" }
```

If the member's `[package].version` does not satisfy the constraint, the build
fails.

### 3.2 Registry form (unchanged)

```toml
"Lyric.Cache" = "0.1.0"
```

Resolved from the configured package registry. If a workspace member with the
same name exists, it is **not** automatically substituted — the registry form
always resolves from the registry. This lets a package pin a specific published
version of a sibling while the rest of the workspace uses the local source.

### 3.3 Git form

For external packages that have not been published to a registry:

```toml
[dependencies]
"SomeLib" = { git = "https://github.com/user/repo", tag = "v1.0.0" }
```

**Supported ref types:**

| Key      | Stability   | Notes |
|----------|-------------|-------|
| `tag`    | Immutable   | Preferred for production. Pinned in the lock file. |
| `rev`    | Immutable   | A full or unambiguous abbreviated commit SHA. |
| `branch` | Mutable     | Warning emitted at build time; not allowed in published packages (§5). |

**Monorepo subdir.** When the target repository contains multiple Lyric
packages (as this repository does), the `subdir` key narrows the resolution to
a specific directory within the clone:

```toml
"Lyric.Cache" = {
  git    = "https://github.com/nichobbs/lyric-lang",
  tag    = "v0.1.0",
  subdir = "lyric-cache",
}
```

The `lyric.toml` inside `subdir` is used as the package manifest. Its
dependencies are resolved recursively.

**Clone cache.** Git sources are cloned (shallow where possible) into
`~/.lyric/git-cache/<url-hash>/<rev>/`. The cache is keyed on the resolved
commit, so repeated builds do not re-clone. `lyric update` refreshes mutable
refs (`branch`) and updates the lock file.

### 3.4 Workspace overrides

When developing against a fork of an external package, adding a dep entry to
every affected member is impractical. The workspace root can redirect any dep
to a local path:

```toml
# lyric.toml — workspace root

[workspace]
exclude = []

[workspace.overrides]
"SomeExternalLib" = { path = "../my-local-fork" }
```

Overrides apply regardless of the dep's declared source form (registry, git, or
path). They take precedence over member-level declarations. Overrides are local
development tools and must not be committed to published packages — the
toolchain emits a warning if `[workspace.overrides]` is non-empty when
`lyric publish` runs.

---

## 4. Transitive native dependencies

`[nuget]` / `[platform.dotnet]` and `[maven]` / `[platform.jvm]` entries in a
library's `lyric.toml` declare the library's native boundary — the point at which
Lyric code delegates to a host platform assembly.

> **Naming note.** The current toolchain uses the table names `[nuget]` and
> `[maven]`. §8 proposes renaming them to `[platform.dotnet]` and
> `[platform.jvm]` to make their library-only role explicit. Examples in §9
> already use the proposed names to pressure-test the rename. Until a
> decision-log entry resolves Q-W-003, treat both names as equivalent.

These entries are:

- **Propagated transitively.** When a project depends on `Lyric.Grpc`, the
  toolchain reads `Grpc.Net.Client = "2.65.0"` from `lyric-grpc`'s manifest and
  includes it in the NuGet restore graph automatically.
- **Invisible to application developers.** Application manifests do not need to
  repeat `[nuget]` or `[maven]` entries for libraries they consume. The only
  entries an application needs are its direct Lyric-level dependencies.
- **Published with the package.** When a library is published to a registry, its
  `[nuget]` / `[maven]` entries are embedded in the registry metadata so
  downstream resolvers can propagate them without fetching the original source.

This model makes `[nuget]` and `[maven]` a library-author concern, not an
application-developer concern.

---

## 5. Publishing behavior

When `lyric publish` runs for a workspace member:

1. Every `{ workspace = true }` dep is substituted with a registry-form dep
   at the member's declared `[package].version`. If the sibling has not been
   published at that version, the publish fails with a list of unpublished
   dependencies.
2. `{ git, branch = "..." }` deps are rejected — mutable refs cannot appear in
   a published manifest.
3. `{ git, tag = "..." }` and `{ git, rev = "..." }` deps are pinned to their
   resolved commit SHA and are allowed in published manifests.  The lock file
   records the exact `rev` so consumers reproduce the same clone.
4. `[workspace.overrides]` entries trigger a warning (see §3.4).
5. The resulting manifest (with path deps replaced by registry refs) is what
   appears in the registry.

Publishing order within a workspace is the caller's responsibility. A future
`lyric publish --workspace` command (not in scope for this sketch) could
automate topological ordering.

---

## 6. Lock file

A single `lyric.lock` at the workspace root (or project root for non-workspace
projects) pins the full resolved dep graph:

```toml
# lyric.lock — machine-generated, commit to version control

[workspace]
version = 1

[[package]]
name    = "Lyric.Cache"
version = "0.1.0"
source  = "workspace"
path    = "lyric-cache"

[[package]]
name    = "SomeLib"
version = "1.0.0"
source  = { git = "https://github.com/user/repo", rev = "d4f9a1b2c3e..." }

# [[package.platform.dotnet]] is a TOML sub-array nested under the preceding
# [[package]] element (SomeLib in this case).  Each entry represents a NuGet
# package that SomeLib's kernel code wraps and that must be included in the
# NuGet restore graph for any consumer of SomeLib.
[[package.platform.dotnet]]
name    = "Grpc.Net.Client"
version = "2.65.0"
source  = "nuget"
```

Member-level lock files are not supported — workspace resolution is unified.
The lock file is committed to version control so that CI and contributors
reproduce the same dep graph.

---

## 7. CLI integration

| Command | Workspace behaviour |
|---|---|
| `lyric build` | Builds all members in dependency order (incremental). |
| `lyric build --package Lyric.Cache` | Builds a specific member and its transitive workspace deps. |
| `lyric test` | Runs all member test suites in dependency order. |
| `lyric restore` | Restores NuGet / Maven deps for all members transitively. |
| `lyric publish` | Runs per-member only; no bulk publish. |
| `lyric update` | Refreshes mutable git refs and registry versions; rewrites lock file. |

`lyric build` without `--package` at a non-workspace project root behaves
identically to the current standalone build.

---

## 8. Exploring native dep elimination (Q-W-001–Q-W-004)

The transitive propagation in §4 already removes `[nuget]` / `[maven]` from
application manifests. A further step would be to prohibit these tables in
application manifests and eventually rename them to make their library-only role
explicit.

**Proposed rename:** `[nuget]` → `[platform.dotnet]`, `[maven]` → `[platform.jvm]`.

**Proposed enforcement:** The toolchain emits an error when a manifest with
`[platform.*]` entries also has `output = "executable"` (i.e., it is an
application, not a library). Libraries keep `[platform.*]` freely.

**Implications and open questions:**

**Q-W-001** — How does a developer use an arbitrary NuGet package that has no
Lyric wrapper yet? Requiring a wrapper library for every native dep adds
ceremony. One escape hatch: an `@unsafe_native` annotation on the dep entry
that explicitly opts out of the prohibition and emits a prominent warning. Risk:
the escape hatch becomes the norm.

**Q-W-002** — Published manifest format. When a library with `[platform.dotnet]`
entries is published, the registry must embed those entries so downstream
`lyric restore` can reconstruct the NuGet graph without fetching the source. The
lock file format in §6 already accommodates this (`[[package.platform.dotnet]]`).
The question is whether the registry metadata format needs a version bump or
whether the existing `Lyric.Contract` embedded resource (D-progress-031) can
carry this information.

**Q-W-003** — Is renaming `[nuget]` → `[platform.dotnet]` a sufficient semantic
change to justify a migration cost? The alternative is to leave the key names
unchanged and rely solely on enforcement (error on `[nuget]` in application
manifests). The rename signals intent more clearly but requires updating all
existing library manifests.

**Q-W-004** — Migration path for existing `[nuget]` / `[maven]` entries in
application manifests. A mechanical codemod (`lyric migrate --workspace`) could:
1. Move `[nuget]` / `[maven]` entries from application manifests into a
   generated wrapper library.
2. Add a workspace dep on that wrapper in the application manifest.

This is feasible but adds a new package to the workspace for every application
that currently has native deps. The alternative — just deleting the application-
level entries and relying on transitive propagation from library deps — works
only if every native dep the application currently declares is already listed
transitively through a Lyric library.

These questions are tracked here until a decision-log entry resolves them.

---

## 9. Example: this repository

The root `lyric.toml` for the `nichobbs/lyric-lang` monorepo under this design:

```toml
# lyric.toml — workspace root (virtual; no [package])

[workspace]
exclude = [
  "bootstrap",     # F# compiler; not a Lyric package
  "resolver",      # Java-side Maven resolver JAR
  "book",          # documentation; no lyric.toml
  "docs",          # documentation; no lyric.toml
  "scripts",       # shell scripts; no lyric.toml
]
```

A library member that depends on `Lyric.Cache` and `Lyric.Resilience`:

```toml
# lyric-jobs/lyric.toml

[package]
name    = "Lyric.Jobs"
version = "0.1.0"

[dependencies]
"Lyric.Stdlib"    = { workspace = true }
"Lyric.Resilience" = { workspace = true }
"Lyric.Cache"     = { workspace = true }

[platform.dotnet]
"Hangfire.Core"      = "1.8.14"
"Hangfire.SqlServer" = "1.8.14"
"Quartz"             = "3.9.0"
```

An application in `examples/ledger` that consumes ecosystem libraries:

```toml
# examples/ledger/lyric.toml

[package]
name    = "Ledger"
version = "0.1.0"
output  = "executable"

[dependencies]
"Lyric.Stdlib"  = { workspace = true }
"Lyric.Web"     = { workspace = true }
"Lyric.Db"      = { workspace = true }
"Lyric.Health"  = { workspace = true }
"Lyric.OTel"    = { workspace = true }

# No [nuget] or [platform.*] needed — propagated transitively from above.
```

An external project (outside this repo) consuming these libraries after
publication to a registry:

```toml
# my-app/lyric.toml — standalone, no workspace

[package]
name    = "MyApp"
version = "1.0.0"
output  = "executable"

[dependencies]
"Lyric.Stdlib" = "0.1.0"
"Lyric.Web"    = "0.1.0"
"Lyric.Cache"  = "0.1.0"

# No [nuget] — transitive NuGet deps propagated from the library manifests.
```

An external project that consumes a pre-release version of `lyric-cache` not
yet published to the registry:

```toml
[dependencies]
"Lyric.Stdlib" = "0.1.0"
"Lyric.Cache"  = {
  git    = "https://github.com/nichobbs/lyric-lang",
  tag    = "v0.2.0-beta.1",
  subdir = "lyric-cache",
}
```
