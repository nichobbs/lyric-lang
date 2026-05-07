# 24 — Build Features (compile-time gating)

**Status:** Drafted.  v1 implementation in progress.
**Implementation:** prerequisite for `docs/25-config-blocks.md` and
`docs/26-aspects.md`. No phase commitment yet; can land any time after
M5.1 stage 5'.
**Decision-log entry:** D045.

> **v1 scope note.** The first implementation ships a deliberately
> narrow subset of the design below: `[features]` with a `default`
> array (no implication arrays); `@cfg(feature = "X")` only (no
> `any` / `all` / `not` — multiple `@cfg` annotations on one item AND
> together); CLI flags `--features`, `--no-default-features`,
> `--all-features`; item erasure during type-checking. Implication
> arrays and boolean predicate composition are deferred to v1.1; the
> design below describes the full target.

---

## 1. Motivation

Lyric needs a way to gate compilation of an item — a `func`, a `type`,
an `aspect`, a whole package — on a build-time selector. The two
driving use cases:

1. **Aspects** (`docs/26-aspects.md`) want to ship `Logging`,
   `Tracing`, `Metrics` aspects in one source tree but compile only
   the subset a given build asks for. Without this, every build pays
   the wrapper cost for every aspect, even ones the deployment doesn't
   want.
2. **Platform-specific code** — a future `Std.Process` extern that
   varies between Windows and Unix has no clean way to pick the right
   shim today. Both branches compile and the wrong one wins.

The need is general enough that aspects shouldn't own it. This document
specifies a Cargo-style **feature** mechanism on `lyric.toml` plus a
`@cfg(...)` annotation that gates source items.

This is a *compile-time* selector only. Runtime configuration is
`docs/25-config-blocks.md`'s job.

---

## 2. Manifest schema

A new `[features]` section in `lyric.toml`:

```toml
[package]
name    = "MyApp"
version = "0.1.0"

[features]
default = ["logging"]            # active when no --features is passed
logging = []                     # bare feature, no implications
tracing = ["logging"]            # implies logging
metrics = []
debug   = ["tracing", "metrics"] # umbrella feature
```

### 2.1 Schema rules

- **Feature names** are bare TOML keys: alphanumeric + `_`/`-`,
  case-sensitive. Convention is `lower_snake`.
- **Feature values** are arrays of feature names. Each named feature
  is *implied* — selecting `tracing` selects `logging` automatically.
- **`default`** is a special key naming features that activate when
  the user does not pass `--features` / `--no-default-features`.
  Optional; if absent, no features are on by default.
- **Implications form a DAG.** Cycles error at manifest parse time
  (`F0001: cycle in feature implications: tracing → logging → tracing`).
- **Unknown feature names** in implication arrays error
  (`F0002: feature 'tracinng' referenced by 'debug' is not declared`).

### 2.2 No cross-package features in v1

A package's features are private to that package. Importing
`SomePackage` doesn't let the importer enable `SomePackage`'s features.
This keeps the dependency graph simple and avoids the Cargo-style
"feature unification across the workspace" tarpit.

If a package wants to expose configurable behaviour to importers, it
should use `docs/25-config-blocks.md` (runtime) or expose explicit
type-level selectors (compile-time).

Cross-package feature plumbing is **deferred**; tracked as Q-features-001.

---

## 3. CLI flags

`lyric build`, `lyric run`, `lyric test`, `lyric prove`, `lyric publish`
all accept:

| Flag | Effect |
|---|---|
| `--features <list>` | Activate the listed features (comma-separated) **in addition to** the manifest's `default`. |
| `--no-default-features` | Suppress the manifest's `default` set. Combine with `--features` to fully control activation. |
| `--all-features` | Activate every feature declared in the manifest (transitively closed). Convenience for `lyric test`. |

Examples:

```sh
lyric build                                    # default=["logging"]
lyric build --features tracing                 # logging + tracing
lyric build --no-default-features              # nothing on
lyric build --no-default-features --features metrics
lyric test --all-features                      # everything on
```

### 3.1 Active feature set

The compiler computes the **active feature set** at build start:

```
active = transitive_closure(
  (default if --no-default-features not set else ∅) ∪ --features
)
```

`--all-features` short-circuits to `transitive_closure(all declared
features)`.

The active set is fixed for the entire build. It is recorded in the
`Lyric.BuildInfo` resource embedded in the output assembly:

```json
{
  "features": ["logging", "tracing"],
  "feature_default": ["logging"],
  "no_default_features": false,
  "all_features": false
}
```

Tooling (`lyric explain`, the LSP, IDE diagnostics) reads this
resource so a user inspecting a built DLL can see which features were
on.

---

## 4. The `@cfg` annotation

Source items gate on the active feature set via `@cfg(...)`:

```lyric
@cfg(feature = "logging")
aspect Logging { ... }

@cfg(any(feature = "logging", feature = "tracing"))
func emitSpan(name: in String): Unit { ... }

@cfg(all(feature = "metrics", not(feature = "debug")))
type MetricRegistry = ...
```

### 4.1 Predicate grammar

```ebnf
cfg-pred  = atom | "all" "(" pred-list ")" | "any" "(" pred-list ")" | "not" "(" cfg-pred ")"
atom      = "feature" "=" string-literal
pred-list = cfg-pred ("," cfg-pred)*
```

Future atom kinds (target, debug-build, etc.) extend `atom` without
breaking the grammar:

```
@cfg(target_os = "linux")               # future
@cfg(debug_assertions)                  # future
```

`feature = "X"` is the only atom in v1.

### 4.2 What can be gated

- Top-level items: `func`, `type`, `aspect`, `wire`, `config`, `let` /
  `val` constants, `package`-private and `pub` alike.
- Whole-package gating via `@cfg(...)` on the `package` declaration:
  if the predicate is false, the package is treated as not present in
  the build (importers see "package not found" diagnostics, not
  type-check errors deep inside).
- Whole-file gating via a `@cfg(...)` immediately after a module-doc
  `//!` comment, before the `package` line.

In v1, gating **inside** items (statement-level, expression-level,
field-level) is not supported. If a function body needs to vary, write
two functions and gate each with `@cfg`.

### 4.3 Erasure semantics

When `@cfg(...)` evaluates to false against the active feature set:

- The item is **not lexed past its declaration header.** (Same rule as
  Rust: the body is parsed but not type-checked, so syntactically
  valid garbage compiles; future tightening tracked as Q-features-002.)
- No metadata is emitted (no `Lyric.Contract.<X>` resource entry, no
  IL).
- Imports referencing the gated item from elsewhere in the same build
  fail at the import site:
  `F0010: 'MyApp.Logging' is gated off by @cfg(feature = "logging")`.
- Imports from another package compiled with different features see
  the item or not based on **that package's** active set, not the
  consumer's. Cross-build mismatches surface as ordinary
  "symbol not found" errors at consumer compile time.

### 4.4 Mutual exclusion

Two items with the same name and disjoint `@cfg` predicates are
allowed and act as a compile-time switch:

```lyric
@cfg(target_os = "linux")
func openConsole(): Result[Handle, IOError] = ...

@cfg(target_os = "windows")
func openConsole(): Result[Handle, IOError] = ...
```

The compiler enforces that **at most one** matches the active set. If
two predicates can both be true under some active set, that's a
compile error (`F0011: overlapping @cfg predicates on item 'X'`).

---

## 5. Diagnostics

| Code | Meaning |
|---|---|
| `F0001` | Cycle in feature implications. |
| `F0002` | Unknown feature referenced in implication array. |
| `F0003` | `--features` names a feature not declared in the manifest. |
| `F0004` | Manifest `default` references an undeclared feature. |
| `F0010` | Import targets an item gated off in the current build. |
| `F0011` | Overlapping `@cfg` predicates on items sharing a name. |
| `F0012` | Malformed `@cfg(...)` predicate syntax. |
| `F0013` | `feature = "X"` references a feature not declared in the manifest. |

`F0013` is the friendliest catch — typos in `@cfg` predicates are
otherwise silent (the predicate just evaluates to false and the item
is erased without warning).

---

## 6. Interaction with other features

- **Contracts.** A gated-off function has no contract obligations on
  its callers because it doesn't exist. A gated-off `requires:` clause
  on an aspect (gated separately from the aspect itself, if we ever
  allow that — currently disallowed) would be an erasure of the
  obligation; that's why this v1 only allows gating whole items.
- **Verifier.** Gated-off items contribute no verification conditions.
  The verifier reads the active feature set from `Lyric.BuildInfo` so
  proofs are reproducible per-build.
- **`lyric publish`.** A published `.dll` is feature-resolved at
  publish time. The published metadata records which features were
  on; downstream consumers cannot toggle them. If a library author
  wants to ship multiple feature combinations, they publish multiple
  artifacts with distinct names.

---

## 7. Out of scope

- **Cross-package feature unification.** A consumer enabling features
  on a dependency. Cargo's headline feature; deferred (Q-features-001).
- **Per-build override of a published library's features.** Same
  question, same deferral.
- **Statement-level / expression-level `@cfg`.** Two functions are the
  workaround.
- **Feature flags resolved at runtime.** That's `docs/25-config-blocks.md`'s
  domain; if you want to flip behaviour without recompiling, use a
  config block.
- **Boolean DSL beyond `all` / `any` / `not`.** No XOR, no implication
  operator, no mathematical sets.

---

## 8. Open questions

- **Q-features-001:** Cross-package feature plumbing. Cargo's design
  is the reference; the unification problem (multiple consumers
  picking different feature sets for a shared dependency) is
  non-trivial. Defer until a real consumer demands it.
- **Q-features-002:** Body parsing of erased items. Rust accepts
  syntactic-but-not-semantic garbage inside `#[cfg(false)]` items.
  Stricter behaviour (full parse but no type-check) is plausible;
  unclear if worth the test-matrix cost.
- **Q-features-003:** Should the active feature set be visible to
  *running* code (e.g. via `Std.BuildInfo.features`)? Useful for
  diagnostics ("which build of the binary am I looking at?"), but
  conflicts with the "compile-time only" framing. Lean toward "yes,
  read-only, via stdlib".

---

## 9. References

- Cargo's feature system:
  https://doc.rust-lang.org/cargo/reference/features.html
- Rust's `#[cfg(...)]`:
  https://doc.rust-lang.org/reference/conditional-compilation.html
- D-progress-077 (lyric.toml manifest parser): the existing manifest
  infrastructure this extends.
