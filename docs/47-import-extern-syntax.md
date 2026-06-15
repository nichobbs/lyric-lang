# 47 — Import Extern Syntax for External Types

**Status:** Specced (D105). Design questions Q47-001–Q47-004 are resolved.
Parser support is in place (PR #3728). Type-checker integration is deferred
to Phase 2 (tracked separately).

**Builds on:** `docs/01-language-reference.md` §11 (FFI), `docs/42-extern-metadata-resolution.md` (metadata-based resolution), `docs/14-native-stdlib-plan.md` (kernel boundary).

**Decision-log entry:** D105 (design decisions for Q47-001–Q47-004).

**Goal:** Unify the syntax for importing Lyric packages and external types,
reducing FFI boilerplate and making the boundary between Lyric and host
code clearer through consistent aliasing conventions.

---

## 1. Motivation

Currently, importing a Lyric type and an external type use different syntax:

```lyric
// Lyric package import
import Std.Core.{Option, Result}

// External type declaration (multiple lines per type)
extern type HostConfig = "Docker.DotNet.DockerClientConfiguration"
extern type HostClient = "Docker.DotNet.DockerClient"
```

This asymmetry creates friction:

1. **Inconsistent patterns** — developers must learn two import mechanisms.
2. **Aliasing mismatch** — Lyric imports support renaming (`as HostConfig`),
   but `extern type` declarations bury the alias in a separate form.
3. **Boilerplate** — importing 5 external types requires 5 lines, one per type,
   instead of grouping them.
4. **Unclear boundary** — `extern type` declarations are scattered; a quick
   scan of a file doesn't immediately show which external types are in use.

---

## 2. Design

### 2.1 Syntax

```lyric
import extern Docker.DotNet.{
  DockerClient as HostClient,
  DockerClientConfiguration as HostConfig
}
```

or with `"` for clarity (external is a separate namespace):

```lyric
import extern "Docker.DotNet".{
  DockerClient as HostClient,
  DockerClientConfiguration as HostConfig
}
```

**Parsing:**
- `import extern` is a new keyword pair (or `extern` becomes a keyword modifier on `import`).
- The identifier(s) after `extern` are **external FQNs**, not Lyric package names.
- Aliasing via `as` works identically to regular imports.
- Unaliased imports (`DockerClient` without `as HostClient`) bind the external
  type under its short name (`DockerClient`).

**Resolution:**
- At type-check time, the compiler records that `HostClient` is an alias for
  the external type `Docker.DotNet.DockerClient`.
- Auto-FFI calls on `HostClient` resolve through metadata (Phase 3c+).
- No `extern type` declaration is required when using `import extern`.

### 2.2 Scope and visibility

External types imported via `import extern` are **scoped to the current package**.

```lyric
// docker_kernel.l
import extern Docker.DotNet.{DockerClient as HostClient}

pub opaque type Client { handle: HostClient }
```

```lyric
// docker.l (different package)
import extern Docker.DotNet.{DockerClient as HostClient}  // must be redeclared

pub func create(): Client { ... }
```

This matches Lyric's import semantics: each file imports what it uses.

---

## 3. Impact on existing code

### 3.1 Backwards compatibility

The `extern type` syntax remains valid and unchanged:

```lyric
extern type HostClient = "Docker.DotNet.DockerClient"
```

Both forms may coexist in a single package. Over time, new code uses
`import extern`; migration of existing code is optional.

### 3.2 Comparison to current stdlib pattern

**Current** (`lyric-stdlib/std/_kernel/http_host.l`):
```lyric
extern type HttpClient = "System.Net.Http.HttpClient"
extern type HttpClientHandler = "System.Net.Http.HttpClientHandler"
extern type HttpRequestMessage = "System.Net.Http.HttpRequestMessage"
extern type HttpResponseMessage = "System.Net.Http.HttpResponseMessage"
```

**With import extern:**
```lyric
import extern System.Net.Http.{
  HttpClient,
  HttpClientHandler,
  HttpRequestMessage,
  HttpResponseMessage
}
```

**Trade-off:** For small type sets (2–3 types), LOC is neutral or slightly higher (4 lines → 6 lines including braces). However, the grouped declaration provides immediate clarity: scanning the file shows exactly which external types are imported and makes the FFI boundary visible at a glance, rather than scattered throughout the file.

**Benefit for larger sets:** For 6+ types, the grouping reduces repetition and duplication of the namespace path. The motivation is not line-count reduction but **clarity and maintainability** — when a file uses many external types, having them declared together in one place prevents accidental duplication and makes auditing the FFI surface straightforward.

---

## 4. Implementation notes

### 4.1 Parser

1. Add `import extern` as a new import form in the grammar.
2. Parse the module path (same as regular imports, but understood to be external).
3. Parse the type list with optional `as` aliases.

### 4.2 Type checker

1. When binding an `import extern` name, record it as an external type reference.
2. At resolution sites (method calls, constructor calls), look up the external
   FQN associated with the alias.
3. Feed the FQN into the existing auto-FFI and metadata-resolution machinery
   (Phase 3c+).

### 4.3 Code generation

No new codegen logic needed — all work happens in the type checker and
existing auto-FFI lowering.

---

## 5. Open questions

- **Q47-001** — Namespace syntax: should `import extern Docker.DotNet` require
  the full FQN (assembly + namespace)? Or should the compiler search known
  reference assemblies by namespace (e.g., `import extern Http { HttpClient }`
  resolves to the first assembly containing an `Http` namespace)? Recommendation:
  require full FQN; ambiguity is a foot-gun.

- **Q47-002** — Collision handling: if a file imports `import extern Docker.DotNet
  { DockerClient }` and also declares a local type `DockerClient`, which wins?
  Recommendation: **local types shadow external imports** (standard scoping rule).
  No compile error; the local type is in scope and the external import is hidden.
  This matches how `import Std.Core.{ Option }` behaves if a local `Option` is
  declared in the same package — the local definition wins.

- **Q47-003** — Documentation and tooling: should `lyric doc` render external
  types differently? Should `lyric public-api-diff` detect when an external
  import changes? Recommendation: external types are not part of the public API
  surface; imports are implementation details.

- **Q47-004** — Visibility modifiers: should `import extern` be allowed in
  `pub use` re-exports? (E.g., `pub use Docker.DotNet { DockerClient }` to
  transitively expose an external type.) Recommendation: yes, with a caveat
  that users of that public API depend on Docker.DotNet's availability.

---

## 6. Alternatives considered

### Option A: Import-like syntax (chosen)

```lyric
import extern Docker.DotNet.{DockerClient as HostClient}
```

**Pros:** Familiar, minimal new syntax, aliases at import site.

### Option B: Namespace-level import

```lyric
import extern Docker.DotNet.*
```

**Pros:** Shorter for large namespaces.

**Cons:** Defeats auditability (which types are in use?); potential for name
collision.

### Option C: Quoted assembly notation

```lyric
import "Docker.DotNet".{DockerClient}
```

**Pros:** Visually distinct (quotes signal external).

**Cons:** Quotes are unusual for imports; may confuse developers.

### Option D: Keep extern type (status quo)

**Pros:** No language changes.

**Cons:** Boilerplate, scattered declarations, inconsistent with Lyric imports.

---

## 7. References

- `docs/01-language-reference.md` §11 (FFI, extern types).
- `docs/42-extern-metadata-resolution.md` (metadata-based resolution enabling
  direct external type references).
- Epic #1622 (metadata-based extern signature resolution, which enables
  auto-FFI on imported external types).
