# 60 — Build defines (compile-time value injection)

**Status:** Unbacked sketch. Pressure-tests a compile-time
*value-injection* mechanism for the self-hosted compiler. Q-BD-001 –
Q-BD-008 below are resolved in this draft; a decision-log entry codifies
them before implementation.
**Builds on:** `docs/24-build-features.md` (D045 — the `[features]` /
`@cfg` compile-time *erasure* mechanism this parallels for *substitution*;
the "compile-time vs runtime" boundary in §1.1 governs both),
`docs/22-distribution-and-tooling.md` §5 + D127 (the version-embedding
workaround this generalizes), `docs/25-config-blocks.md` (D046 — the
runtime-config axis a define is explicitly *not*).
**Decision-log entry:** none yet.

---

## 1. Motivation

The self-hosted compiler can *erase* an item conditionally
(`@cfg(feature = "X")`, `lyric-compiler/lyric/cfg.l`, run in the
`pipeParseAndErase` pipeline stage) but has no way to *substitute a
value* into a `.l` source literal at compile time. `version.l`'s own
header states the gap:

> The self-hosted compiler has no macro or build-flag mechanism to inject
> a value into a `.l` source literal at compile time, so this reads it
> from the environment instead …

D127 closed the *version* instance of this gap with a **runtime** read —
`Std.Environment.getVarOrDefault("LYRIC_BUILD_VERSION", "0.1.0")`, with
the env var set by the C# AOT trampoline (`Program.cs`). That is correct
for the one value it targets, but it is not a general mechanism, and it
has structural costs a compile-time solution avoids:

- **Runtime, not baked.** The value is resolved when the binary *runs*,
  from an env var that must be present at exec time. It is not an
  `ldstr` constant in the assembly (the env-var read is; the *value*
  isn't).
- **Non-self-hosted hop.** The value only reaches Lyric because a C#
  trampoline sets the env var. A user program compiled with `lyric build`
  has no equivalent.
- **No const-folding.** A runtime env read cannot feed a `@cfg`
  predicate, a `match` const-pattern (`docs/46`), or a contract clause.
- **Per-value plumbing.** Every new build-time value (git SHA, build
  timestamp, target triple, an embedded asset's hash) would need its own
  env var, its own trampoline line, its own fallback.

Build defines close the gap generally: a build parameter — declared in
the manifest and/or passed on the CLI — is substituted into the AST as a
**string literal node** before type-checking, exactly where `@cfg`
erasure already runs. After substitution it is an ordinary literal, so it
is a real `ldstr`/`ldc`, survives Native AOT trimming, works identically
on MSIL / JVM / native, and needs **zero backend codegen changes**.

### 1.1 Compile-time substitution — runtime behaviour still goes through D046

A build define shares docs/24 §1.1's framing: it is a **publish-time,
compile-time** mechanism. The substituted literal is baked into the
output; a downstream consumer of a published `.dll` cannot re-inject it
(§7 / Q-BD-007). If you need a value that varies *per deployment of an
already-built binary*, that is runtime config (`docs/25`, D046), not a
define. The rule of thumb mirrors `@cfg`:

| Need | Right tool |
|---|---|
| "Bake the release version / git SHA into the binary" | `@build_const` define |
| "Pick the log level at deploy time" | `config { … }` (D046) |
| "Compile out an aspect this build doesn't want" | `@cfg` (D045) |

`@cfg` answers *"is this item in my binary?"*; a **define** answers
*"what literal value does this constant hold in my binary?"*; D046
answers *"given the binary, what does it do at runtime?"*.

---

## 2. Two source spellings

Two spellings can express "substitute a build value here." This sketch
recommends the **annotation form** (Q-BD-001); both are shown so the
tension is on record.

### 2.1 Annotation form (recommended)

An annotation on a module-level `val` constant. The initializer literal
stays in the source as the **dev-checkout fallback**; the compiler
overwrites it with the resolved define when one is supplied.

```lyric
package Lyric.Version

// Reads the `version` define at build time; falls back to the literal
// when no define is supplied (a plain `make lyric` / dev checkout).
@build_const("version")
pub val VERSION: String = "0.1.0"
```

At other sites the constant is referenced normally — it is just a `val`:

```lyric
func banner(): String { "lyric " + VERSION }
```

Properties:

- **Always a valid, parseable literal.** `lyric fmt` sees a normal `val`;
  no formatter special-casing, no P0020 risk. The loss-checked formatter
  (`Lyric.Fmt.formatSourceChecked`) round-trips it unchanged.
- **The fallback is in the source, not the mechanism.** A missing define
  is not an error — it is the dev path. This removes an entire diagnostic
  class (§6, Q-BD-004).
- **One substitution point per value.** The value has a single named home
  (`VERSION`); every use is an ordinary identifier reference, so nothing
  downstream needs to know a define was involved.

### 2.2 Intrinsic-call form (alternative)

A compiler-recognized call, Rust-`env!`-style, replaced by a literal node
wherever it appears:

```lyric
func banner(): String { "lyric " + buildValue("version") }

pub val VERSION: String = buildValue("version")
```

Properties (and why it loses to §2.1):

- **No in-source fallback.** `buildValue("version")` with no `version`
  define has nothing to fall back *to*. It must either error at build
  (breaks dev checkouts) or grow a two-arg
  `buildValue("version", "0.1.0")` form — at which point it is the
  annotation's fallback with worse ergonomics and a new call-resolution
  surface in the type checker.
- **New name-resolution surface.** `buildValue` is neither a normal
  function nor a keyword; the resolver (`typechecker_resolver.l`) must
  special-case it, and `lyric fmt` must know it is not a user call.
- **Substitution scattered.** The value can appear anywhere an expression
  can, so the substitution pass must walk every expression rather than
  every top-level `val` initializer — more surface, more edge cases
  (inside interpolation, inside a `match` scrutinee, …).

The annotation form is strictly the smaller, safer surface. Recommended.

---

## 3. Where defines come from

Two sources, composed like `[features]` + `--features`:

### 3.1 Manifest `[build.define]`

```toml
[package]
name    = "MyApp"
version = "0.1.0"

[build.define]
build_channel = "stable"
api_base      = "https://api.example.com"
```

Parsed by `manifest.l` alongside the existing `[build]` table
(`assembleBuild`). Values are TOML strings only (§4). Keys follow the
feature-name convention: alphanumeric + `_`/`-`, case-sensitive,
`lower_snake` by convention.

### 3.2 CLI `--define KEY=VALUE`

`lyric build`, `run`, `test`, `prove`, `publish` accept repeatable
`--define`:

```sh
lyric build --define build_channel=nightly --define git_sha=$(git rev-parse HEAD)
```

**Precedence:** CLI `--define` overrides a manifest `[build.define]` of
the same key (the same direction `--features` augments/overrides manifest
defaults). This mirrors the `--package-version` precedent
(`cli_build.l`), the existing build-parameter threading D127's rejected
alternative failed to reuse.

### 3.3 Well-known toolchain defines

The toolchain auto-populates a reserved set so common values need no
manual wiring. These are injected by the CLI before user defines are
applied, and a user `--define`/manifest entry of the same key overrides
them:

| Key | Value |
|---|---|
| `version` | resolved release version (the D127 value; from `-p:Version=` / `--package-version`, else the manifest `version`) |
| `target` | active backend: `dotnet` / `jvm` / `native` |
| `build_profile` | `debug` / `release` |

`git_sha`, `build_timestamp`, etc. are **not** auto-injected —
reproducibility (§8 / Q-BD-006) makes timestamps a deliberate opt-in, not
a default.

---

## 4. Value type — `String` only (v1)

Substituted values are `String` literals. `version`, `git_sha`,
`build_channel`, `target`, `api_base` are all strings; a program that
wants an `Int` parses it (`Std.Core` int-parse) at the use site. `Int` /
`Bool` defines are deferred (Q-BD-002) — they invite const-fold-into-`@cfg`
scope creep (Q-BD-005) that v1 explicitly excludes.

The annotated `val` **must** be declared `String`; a `@build_const` on a
non-`String` `val` is `F0030` (§6).

---

## 5. Pipeline placement

Substitution is a new AST pass in `pipeParseAndErase`
(`lyric-compiler/lyric/pipeline/pipeline.l:94`), running **beside** — and
ordered **before** — `Cfg.applyCfgErasure`:

```
pipeParseAndErase(source, activeFeatures, declaredFeatures, defines, targetName):
    parse
    → applyBuildDefines(defines, ast)        # NEW: overwrite @build_const initializers
    → Cfg.applyCfgErasure(withTargetFeature(activeFeatures, targetName), declared, ast)
```

`applyBuildDefines` walks top-level items; for each `val` carrying a
`@build_const("K")` annotation it replaces the initializer expression with
a `String`-literal AST node holding `defines["K"]`, or leaves the existing
literal untouched when `K` is absent from `defines`. It emits the §6
diagnostics and is otherwise a pure `SourceFile -> SourceFile` transform,
same shape as `applyCfgErasure`.

Threading: the `defines: Map[String, String]` parameter follows the exact
route `activeFeatures` already travels from the CLI through the backend
bridges (`Msil.Bridge` / `Jvm.Bridge` / `Lyric.LlvmBridge`). No new
plumbing topology — one more map alongside the feature list.

**Ordering rationale:** defines run *before* cfg erasure so a define can
never be read from an item cfg is about to erase, and cfg predicates
cannot (in v1) observe a define — the two passes stay independent
(Q-BD-005). Substitution produces a literal node; it does **not** re-parse
the value as source (§8 / Q-BD-008).

---

## 6. Diagnostics

Namespaced `F003x` to sit under docs/24's `F001x`/`F000x` build family:

| Code | Meaning |
|---|---|
| `F0030` | `@build_const` on a `val` whose declared type is not `String`. |
| `F0031` | `@build_const` on an item that is not a module-level `val` (e.g. a `func`, a local `val`). |
| `F0032` | `@build_const("")` / missing or non-string-literal key argument. |
| `F0033` | `--define`/manifest key is not a valid define name (bad chars). |

Deliberately **not** an error: a `@build_const("K")` whose `K` has no
supplied define. That is the dev-checkout fallback path (§2.1) — the
whole point of keeping the literal in source. A *strict* release build can
opt into "every well-known define must be supplied" via a future
`--defines-required` flag (Q-BD-004); v1 does not ship it.

---

## 7. Cross-package boundary — defines are build-private

Identical to docs/24 §2.2's feature-privacy rule. A define is private to
the build that supplies it:

- A published `.dll` bakes its `@build_const` values at `lyric publish`
  time. A consumer importing that package sees the baked literals; it
  **cannot** re-inject a different value (Q-BD-007).
- A workspace/path dependency (built from source in the consumer's tree)
  resolves defines from **its own** manifest `[build.define]`; the root
  build's `--define` list is *not* forwarded (again mirroring the
  features rule for workspace deps, docs/24 §2.3 — explicit root flags
  forwarded for features; defines are not forwarded at all in v1, since a
  define names a value semantically owned by the package declaring the
  `@build_const`).

If a library wants a *consumer*-supplied value, that is runtime config
(D046), not a define — the same answer docs/24 §1.1 gives for features.

---

## 8. Reproducibility, security

**Bootstrap byte-identity (Q-BD-006).** The three-stage reproducibility
bootstrap (`scripts/bootstrap.sh`, F#-free self-compile compare) runs with
**no defines supplied**, so every `@build_const` takes its in-source
fallback literal — the stage-2 and stage-3 outputs are byte-identical by
construction, because the substitution pass is a no-op when `defines` is
empty. A *release* build (`--define version=X`) is a distinct artifact and
is not part of the byte-compare. Timestamp-style defines are opt-in
precisely so the default build stays reproducible.

**No source injection (Q-BD-008).** A define value is inserted **only as a
`String`-literal AST node** — never re-lexed or re-parsed as Lyric source.
`--define x='"; drop table --'` yields a constant whose runtime value is
that exact string; it cannot introduce tokens, close a string early, or
add an item. This is the categorical improvement over both D127's rejected
`scripts/stamp_version.py` regex-rewrite (which edited source text) and
Option D's generated-`.l`-file approach (which emits source): substitution
happens *post-parse, in the AST*, so the grammar is never a value's
concern.

---

## 9. Worked example — re-expressing `version.l` on defines

Today (D127, runtime env read):

```lyric
package Lyric.Version
import Std.Environment as Environment

pub func VERSION(): String {
  Environment.getVarOrDefault("LYRIC_BUILD_VERSION", "0.1.0")
}
```

On build defines (compile-time, self-hosted, no trampoline hop):

```lyric
package Lyric.Version

@build_const("version")
pub val VERSION: String = "0.1.0"
```

`Program.cs` drops its `SetEnvironmentVariable("LYRIC_BUILD_VERSION", …)`
line and returns to a pure trampoline; `version` becomes the first
well-known define (§3.3), fed from the `-p:Version=` value the release
workflow already resolves. `lyric --version` prints an `ldstr` constant
that survives AOT trimming with no attribute-reflection caveat. Every
other consumer of a build value — git SHA in a diagnostic banner, target
triple in an error message — uses the same one annotation.

---

## 10. Out of scope (v1)

- **`Int` / `Bool` defines** (Q-BD-002) — deferred; parse a `String` at
  the use site.
- **Defines feeding `@cfg` predicates or const-patterns** (Q-BD-005) —
  the passes stay independent; a value-atom form of `@cfg`
  (`@cfg(build_channel = "nightly")`) is a separate future design.
- **Intrinsic-call spelling** (Q-BD-001) — the annotation form ships;
  `buildValue(...)` is recorded here as the rejected alternative.
- **Consumer override of a published package's defines** (Q-BD-007) —
  closed, same as cross-package features. Use D046.
- **`--defines-required` strict mode** (Q-BD-004) — deferred; the
  in-source fallback covers dev and the smoke-test asserts the release
  value (as D127's global-tool smoke test already does).

---

## 11. Open questions (resolved in this draft)

- **Q-BD-001 — annotation vs intrinsic spelling?** *Resolved:* annotation
  form `@build_const("K")` on a module-level `val`. It keeps a valid,
  formatter-safe, in-source fallback literal and adds no name-resolution
  surface; the intrinsic `buildValue(...)` has no natural fallback and
  needs resolver/formatter special-casing (§2).
- **Q-BD-002 — value types?** *Resolved:* `String` only in v1; `Int` /
  `Bool` deferred (§4).
- **Q-BD-003 — define source and precedence?** *Resolved:* manifest
  `[build.define]` + repeatable CLI `--define K=V`, CLI overriding
  manifest, both overriding auto-injected well-known defines (§3).
- **Q-BD-004 — missing define at build?** *Resolved:* not an error — the
  in-source literal is the fallback. Strict `--defines-required` deferred
  (§6).
- **Q-BD-005 — participate in const-folding / `@cfg`?** *Resolved:* after
  substitution it is a plain literal and const-folds wherever a literal
  does, but v1 forbids a define feeding a `@cfg` predicate (pass ordering,
  §5); cfg value-atoms are a separate future design.
- **Q-BD-006 — bootstrap reproducibility?** *Resolved:* the byte-compare
  runs with no defines, so every `@build_const` takes its fallback and the
  substitution pass is a no-op — reproducible by construction (§8).
- **Q-BD-007 — cross-package leakage?** *Resolved:* build-private, exactly
  like features; published DLLs bake defines at publish, consumers cannot
  override, workspace deps resolve their own (§7).
- **Q-BD-008 — injection safety?** *Resolved:* values are inserted as
  `String`-literal AST nodes post-parse, never re-parsed as source — no
  grammar surface, categorically safer than text-stamping or generated
  `.l` (§8).

---

## 12. References

- `docs/24-build-features.md` (D045) — the `@cfg` erasure counterpart.
- `docs/22-distribution-and-tooling.md` §5 + D127 — the version workaround
  this generalizes.
- `docs/25-config-blocks.md` (D046) — the runtime-config axis a define is
  not.
- `docs/46-const-patterns.md` — `@Ident` const-pattern references, the
  const-fold surface a future `Int`/`Bool` define could reach (Q-BD-005).
- Rust `env!` / Cargo `cargo:rustc-env`: the intrinsic-spelling prior art
  weighed in §2.2.
