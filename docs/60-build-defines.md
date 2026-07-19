# 60 — Build defines (compile-time value injection)

**Status:** Design sketch; **M1a + M1b + M1c + M1d + M1e + M1f + M1g + M1h shipped**. M1a — the
`@build_const("KEY")` substitution pass (`Lyric.BuildDefines`) + `lyric build
--define KEY=VALUE` for single-file `--target dotnet` builds (diagnostics
F0030–F0032). M1b — the `Std.BuildInfo` layer (§9.2): the
`Std.BuildInfo.BuildInfo` type plus the compiler-synthesized `buildInfo()`
accessor injected into a consumer file that imports `Std.BuildInfo`, running in
the shared `pipeParseAndErase` so it works on all three targets; its `version` /
`profile` / `gitHash` / `buildTimestamp` come from the resolved defines
(deterministic fallbacks otherwise) and `target` / `features` from the build's
own parameters. M1c — `--define` threading to the **JVM and native** bridges
(`EmitRequest.defines` → `compileToJarBundledWithFeatures` /
`compileToNativeWithFlags`), so single-file `--define` (and therefore
`Std.BuildInfo`'s define-sourced fields) now works on `--target dotnet` and
`--target jvm`. **#5977 is closed: `--define` now works on all three targets.**
Native lowers list literals (`[...]` → `lyric_list_new` + `lyric_list_push`), so
`Std.BuildInfo` is functional on `--target native` (its `buildInfo()` accessor's
`features = [...]` compiles and runs, and the well-known `target`/`build_profile`
defines populate); native resolves **module-level `val` references** by inlining
a literal-initialized binding at the use site, so a `@build_const` `val` (whose
initializer is always a `String` literal after substitution) compiles and runs
on native too; and the CLI gate is lifted, so `lyric build --target native
<file.l> --define KEY=VALUE` substitutes correctly. Native builds are
**single-file only** (native has no multi-package/project build path — a native
manifest build is rejected by `buildProject`), so native `--define` is
single-file; the well-known `version`/`build_profile` and manifest
`[build.define]` are project-only and therefore remain MSIL/JVM. The gate widens
to "single-file `--target dotnet`/`jvm`/`native`, plus project builds on
`--target dotnet`/`jvm`" — only `--watch` and `--release`/`[build] kind = "aot"`
stay gated (their rebuild / AOT-packaging paths thread no defines).
M1d — the auto-injected well-known **`version`** define
(`BD.withWellKnownDefines`): the manifest's `[package].version` is injected as a
fallback define on the project path (both the MSIL project bridge and the JVM
project emitter path), so `BuildInfo.version` (and any `@build_const("version")`)
populates on a project build **without** an explicit `--define`. It is a
fallback — an explicit `--define version=…` still wins (`decodeDefines` is
last-wins). Single-file builds carry no manifest version, so they keep the
deterministic `"0.0.0"` fallback. M1e — user `--define` on **project builds**
(`EmitProjectRequest.defines` threaded from the CLI through `emitProject` to both
project bridges; `buildProject` gains a `cliDefines` param): `lyric build`
(explicit `--manifest` or an auto-discovered `lyric.toml`) `--define KEY=VALUE`
now substitutes `@build_const`s and populates the define-sourced `Std.BuildInfo`
fields on a project build, merged beneath the well-known `version` so an explicit
`--define version=…` overrides the manifest. The CLI gate widens to "single-file
or project, `--target dotnet`/`jvm`"; native (#5977), `--watch`, `--release`, and
a manifest `[build] kind = "aot"` (which routes into the same AOT-packaging path
as `--release`, #6139) stay gated — rejected up front rather than silently
dropped. M1f — the auto-injected well-known **`target`** define
(`BD.withWellKnownTarget`): the active backend name (`dotnet` / `jvm` / `native`)
is injected as a fallback define in `pipeParseAndErase` — the one pass that
carries `targetName` on every backend and both the single-file and project paths
— so `@build_const("target")` populates on every build without an explicit
`--define`. It is deterministic per build invocation (reproducibility-safe,
§8) and a fallback: an explicit `--define target=…` still wins. M1g — the
manifest **`[build.define]`** table (§3.1): parsed by `manifest.l`
(`BuildSection.defines`, exposed via `getManifestBuildDefines`) as `"KEY=VALUE"`
strings, layered on a project build beneath CLI `--define`s (`BD.withManifestDefines`
→ CLI wins over a manifest define of the same key, both over the well-known
`version` fallback). A `[build.define]`-only manifest (no `[build]` header)
parses with a default `kind = "lib"`; a non-string value is a manifest error
(§4, String-only). Applied on `--target dotnet`/`jvm` project builds; rejected
up front (no silent drop) on `--target native` (#5977), `--release`, and
`[build] kind = "aot"` (the AOT-packaging path threads no defines). M1h — the
auto-injected well-known **`build_profile`** define (`BD.withWellKnownProfile`):
`pipeParseAndErase` injects `build_profile=debug` on every compile as a fallback;
a `--release`/AOT build injects `build_profile=release` into its staging compile
upstream (`buildReleaseProject`/`buildReleaseSingle`), so `decodeDefines`'
last-wins keeps `release` there. This makes `@build_const("build_profile")` and
`Std.BuildInfo.profile` report `debug`/`release` correctly with no explicit
`--define`, without touching the user-define release gates (those stay rejected;
the profile define is compiler-injected). Deterministic per invocation
(reproducibility-safe, §8). With M1h the full auto-injected well-known set
(`version` / `target` / `build_profile`) ships; only native `--define` (blocked
on native codegen, #5977) remains outstanding under #5852. Q-BD-001 –
Q-BD-009 below are resolved in this draft; a decision-log entry still codifies
the full design.
**Builds on:** `docs/24-build-features.md` (D045 — the `[features]` /
`@cfg` compile-time *erasure* mechanism this parallels for *substitution*;
the "compile-time vs runtime" boundary in §1.1 governs both),
`docs/22-distribution-and-tooling.md` §5 + D127 (the version-embedding
workaround this generalizes), `docs/25-config-blocks.md` (D046 — the
runtime-config axis a define is explicitly *not*).
**Decision-log entry:** none yet — M1a and M1b shipped ahead of a formal
entry; the entry that codifies the full design lands with the
project-path/JVM/native + well-known-defines follow-up (#5852).

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

`git_sha`, `build_timestamp`, etc. are **not** auto-injected: they are the
values that are *not* a pure function of the build configuration, so
auto-injecting them would break the bootstrap byte-compare (§8 / Q-BD-006).
The three that *are* auto-injected are each deterministic for a given build
invocation, which is what keeps reproducibility intact.

---

## 4. Value type — `String` only (v1)

Substituted values are `String` literals. `version`, `git_sha`,
`build_channel`, `target`, `api_base` are all strings; a program that
wants an `Int` parses it (`Std.Core` int-parse) at the use site. `Int` /
`Bool` defines are deferred (Q-BD-002) — they invite const-fold-into-`@cfg`
scope creep (Q-BD-005) that v1 explicitly excludes.

The annotated `val`'s type **must resolve to `String`** — whether written
explicitly (`val VERSION: String = "0.1.0"`) or inferred from the fallback
literal (`val VERSION = "0.1.0"`); both are accepted since the fallback is
always a `String` literal. `F0030` (§6) fires on the *resolved* type, so a
`@build_const` on a `val` whose type resolves to anything other than
`String` is rejected regardless of whether the annotation was present.

---

## 5. Pipeline placement

Substitution is a new AST pass in `pipeParseAndErase`
(`lyric-compiler/lyric/pipeline/pipeline.l:94`), running **beside** — and
ordered **before** — `Cfg.applyCfgErasure`:

```
# real signature today: (source, targetName, activeFeatures, declaredFeatures);
# this proposal appends one `defines` parameter, preserving the existing order.
pipeParseAndErase(source, targetName, activeFeatures, declaredFeatures, defines):
    parse
    → applyBuildDefines(defines, ast)        # NEW: overwrite @build_const initializers
    → Cfg.applyCfgErasure(withTargetFeature(activeFeatures, targetName), declaredFeatures, ast)
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
| `F0030` | `@build_const` on a `val` whose *resolved* type is not `String` (whether written explicitly or inferred from the fallback literal, per §4). |
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

**Bootstrap byte-identity (Q-BD-006).** Reproducibility does not require an
*empty* define set — the well-known defines of §3.3 (`version`, `target`,
`build_profile`) are auto-injected on every build, including the bootstrap.
It requires the resolved define set to be a **deterministic function of the
build configuration**, which those three are: `version` comes from the
manifest (`0.1.0` in a dev checkout, absent a `-p:Version=` override),
`target` and `build_profile` are fixed for a given build invocation. The
three-stage reproducibility bootstrap (`scripts/bootstrap.sh`, F#-free
self-compile compare) runs stage-2 and stage-3 with **identical**
configuration, so both receive identical injected defines and every
`@build_const` substitutes the same literal — the outputs are byte-identical
by construction. The values that are *not* a pure function of the build
inputs — `git_sha`, `build_timestamp` — are deliberately **not**
auto-injected (§3.3); supplying one via `--define` produces a distinct,
intentionally non-bootstrap-comparable artifact. A release build
(`--define version=X`) is likewise a distinct artifact outside the
byte-compare.

**No source injection (Q-BD-008).** A define value is inserted **only as a
`String`-literal AST node** — never re-lexed or re-parsed as Lyric source.
`--define x='"; drop table --'` yields a constant whose runtime value is
that exact string; it cannot introduce tokens, close a string early, or
add an item. This is the categorical improvement over both D127's rejected
`scripts/stamp_version.py` regex-rewrite (which edited source text) and a
`build.rs`-style generated-`.l`-file approach (which emits source):
substitution happens *post-parse, in the AST*, so the grammar is never a
value's concern.

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

On build defines (compile-time, self-hosted, no trampoline hop). The
annotation attaches to a `val`, but every existing call site spells it
`Ver.VERSION()` (a function call — see `cli_shared.l`, `lsp.l`, `repl.l`
in D127), so the public surface stays a zero-argument `func` wrapping the
annotated constant. No call site changes:

```lyric
package Lyric.Version

@build_const("version")
val VERSION_CONST: String = "0.1.0"

pub func VERSION(): String { VERSION_CONST }
```

(Migrating the public surface to a bare `pub val VERSION` would be
cleaner but would break those call sites — dropping the `()` at each — so
the wrapper is the mechanical, no-churn form. A follow-up could collapse
the wrapper and update the three call sites in one pass if desired.)

`Program.cs` drops its `SetEnvironmentVariable("LYRIC_BUILD_VERSION", …)`
line and returns to a pure trampoline; `version` becomes the first
well-known define (§3.3), fed from the `-p:Version=` value the release
workflow already resolves. `lyric --version` prints an `ldstr` constant
that survives AOT trimming with no attribute-reflection caveat. Every
other consumer of a build value — git SHA in a diagnostic banner, target
triple in an error message — uses the same one annotation.

### 9.1 Relationship to platform-native version metadata

Neither .NET nor the JVM offers a *source-level* compile-time
value-injection intrinsic Lyric could lower to (C#'s `ThisAssembly.*`
constants come from a third-party source generator; Java has no analog) —
so build defines remain the right general mechanism. But for the
`version` define **specifically**, both targets have a standard *metadata*
slot the resolved value should **also** be written to, so external tooling
(`dotnet` / NuGet / `ildasm`, `unzip META-INF/MANIFEST.MF`, IDEs,
SBOM/dependency scanners) can discover it the conventional way. The define
and the metadata slot are **complementary sinks of one source**, not
alternatives:

- **Define → baked `ldstr` constant** is what the *running program* reads
  (`lyric --version`). It is the trim-safe source: on .NET Native AOT,
  reading an assembly attribute back via reflection is not guaranteed
  (the exact D127 rationale), so a runtime read cannot rely on the
  metadata slot.
- **Same value → platform metadata slot** is what *external tooling*
  reads, without running the program.

Current state (verified against the emitters), and the small gaps this
exposes:

| Target | Standard slot | Today | Gap |
|---|---|---|---|
| .NET | Assembly row version + `AssemblyInformationalVersionAttribute` | `msil/bridge.l` parses `packageVersion` (`--package-version` / manifest `[package].version`) into the Assembly row's major/minor (`bridge.l:701`) and the contract-meta resource | The Assembly row is numeric only, so a pre-release semver (`1.4.2-rc1`) truncates; emitting `AssemblyInformationalVersionAttribute` (a free-form string) would preserve the full version. |
| JVM | `META-INF/MANIFEST.MF` `Implementation-Version` | `jvm/manifest.l` writes a **non-standard** `Lyric-Version:` header, and the single-file bridge path **hardcodes `"0.1.0"`** (`jvm/bridge.l:219`, `:1573`) — `packageVersion` is not threaded through | `lyric build --target jvm --package-version X` produces a jar whose manifest reports `0.1.0`, a one-platform inconsistency vs. MSIL. Fix: thread `packageVersion` through, and emit the standard `Implementation-Version:` alongside (or instead of) `Lyric-Version:`. |

Both gaps are **pre-existing** and independent of this sketch — build
defines do not depend on them and are not blocked by them — but they are
the natural companion work: once `version` is a first-class well-known
define (§3.3), a single resolved value feeds the runtime constant *and*
both platform metadata slots. The JVM hardcode is tracked as **#5834**
(silent one-platform version drop); the .NET
`AssemblyInformationalVersionAttribute` refinement is a sibling candidate.
Neither is fixed by this docs-only change.

### 9.2 The `Std.BuildInfo` layer — one type for all build metadata

Build defines are the *primitive*; a standardized **`BuildInfo`** surface
is the curated layer a program actually reads. Rather than each program
hand-declaring `@build_const` constants for version / git hash / build
time, the toolchain exposes them through one blessed type. This is the
Lyric analog of Go's `runtime/debug.ReadBuildInfo()` and Rust's `built`
crate — the *toolchain* provides the values; you don't declare them.

**The type lives in stdlib; the values are synthesized into your build.**

```lyric
// lyric-stdlib/std/buildinfo.l  — the TYPE is shared; the VALUES are not.
package Std.BuildInfo

pub record BuildInfo {
  version:        String          // always present — deterministic (§3.3)
  target:         String          // "dotnet" | "jvm" | "native"
  profile:        String          // "debug" | "release"
  gitHash:        Option[String]  // None unless supplied (§8 reproducibility)
  buildTimestamp: Option[String]  // None unless supplied
  features:       List[String]    // active feature set — unifies docs/24 Q-features-003
}
```

A program reads it by importing the module and calling the accessor the
compiler wires into the program's own root package:

```lyric
import Std.BuildInfo

func startupBanner(): String {
  val bi = buildInfo()
  "myapp " + bi.version + " (" + bi.target + "/" + bi.profile + ")"
}
```

**Why synthesized into the *root* package, not a stdlib function reading a
baked constant.** A define is baked at the compile of the package that
declares it (§7). If `buildInfo()` were a stdlib function returning
stdlib-declared `@build_const` values, every program would report the
*stdlib's* build metadata (`0.1.0`, no git hash), not its own — the same
cross-package staleness `version.l` would hit if its constant lived in the
wrong package. Synthesizing the accessor into the **consumer's** root
package (the AST-synthesis pattern already used by `test_synth.l` and
`stubbable.l`, which also inject the imports they need) captures the
consumer's resolved defines. The `BuildInfo` *type* is safe to share from
stdlib because a type carries no per-build value; only the accessor's body
is per-build, and it is generated where the build happens.

**Reproducibility is why `gitHash` / `buildTimestamp` are `Option`.**
`version` / `target` / `profile` are deterministic functions of the build
configuration (§8), so they are always-present `String` fields. `gitHash`
and `buildTimestamp` are *not* pure functions of the config — baking them
by default would break the three-stage byte-compare — so they are
`Option[String]`, `None` unless the build explicitly supplies the
`git_hash` / `build_timestamp` defines. The default (reproducible) build
yields `None`; a release build opts in. The type is the same either way,
so consumers written against it don't change.

**`features` unifies Q-features-003.** docs/24 Q-features-003 asked whether
the active feature set should be visible to running code (it floated a
hypothetical `Std.BuildInfo.features`). Since no `Std.BuildInfo` existed,
this makes it real and folds the feature set into the one build-metadata
type rather than a separate surface — resolving Q-features-003 as "yes,
read-only, via `BuildInfo.features`".

**Relationship to `@build_const`.** The two are independent consumers of
the same resolved-defines map (§5): `@build_const` substitutes one value
into one `val` initializer; the `BuildInfo` synthesis pass reads the
well-known keys (`version`, `target`, `build_profile`, `git_hash`,
`build_timestamp`) plus the active feature list and emits one populated
record constructor. Neither depends on the other — `BuildInfo` can ship
first from the parameters that already flow through the pipeline (version,
target, profile, features), with `gitHash` / `buildTimestamp` wired when a
define *source* (`--define` / `[build.define]`) lands.

**Shipped (M1b).** `Std.BuildInfo` (`lyric-stdlib/std/buildinfo.l`) declares
the `BuildInfo` record; `Lyric.BuildDefines.synthesizeBuildInfo` appends the
`pub func buildInfo(): BuildInfo` accessor to any file whose imports include a
bare `import Std.BuildInfo` (and that does not already declare its own
`buildInfo`). It runs in `pipeParseAndErase` right after `@cfg` erasure, so
every target (`Msil.Bridge`, `Jvm.Bridge`, `Lyric.LlvmBridge`) gets it from one
call site. `target` is the build's target name and `features` its active
feature set (both already threaded); `version` / `profile` read the `version` /
`build_profile` defines with deterministic `"0.0.0"` / `"debug"` fallbacks, and
`gitHash` / `buildTimestamp` are `Some` only when the `git_hash` /
`build_timestamp` defines are supplied (the reproducibility seam). Because the
value source is the resolved-defines map, `version` / `profile` are populated on
the single-file `--target dotnet --define` path today; the auto-injected
well-known defines that would fill them in on every build (from the manifest
version and `--release`) are the next #5852 slice. Verified by
`build_defines_self_test.l` (AST-level: no-op without the import, one accessor
appended with the import, per-field value/fallback/`Option` coverage,
user-`buildInfo` deference) and `buildinfo_self_test.l` (runtime, both targets:
the synthesized accessor's deterministic dev-checkout values).

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
- **Q-BD-006 — bootstrap reproducibility?** *Resolved:* reproducibility
  requires the resolved define set to be a deterministic function of the
  build configuration, not to be empty. The auto-injected well-known
  defines (`version` from the manifest, `target`, `build_profile`) are each
  deterministic per invocation, so stage-2 and stage-3 substitute identical
  literals and stay byte-identical; non-deterministic values (`git_sha`,
  `build_timestamp`) are deliberately never auto-injected (§8).
- **Q-BD-007 — cross-package leakage?** *Resolved:* build-private, exactly
  like features; published DLLs bake defines at publish, consumers cannot
  override, workspace deps resolve their own (§7).
- **Q-BD-008 — injection safety?** *Resolved:* values are inserted as
  `String`-literal AST nodes post-parse, never re-parsed as source — no
  grammar surface, categorically safer than text-stamping or generated
  `.l` (§8).
- **Q-BD-009 — a standardized `BuildInfo` surface?** *Resolved:* yes —
  a stdlib `Std.BuildInfo.BuildInfo` record plus a compiler-synthesized
  `buildInfo()` accessor injected into the consumer's **root** package
  (Go `debug.ReadBuildInfo()` model), so it captures the consumer's build,
  not the stdlib's (§9.2). `version` / `target` / `profile` are always-
  present deterministic `String` fields; `gitHash` / `buildTimestamp` are
  `Option[String]` (`None` unless supplied, preserving reproducibility);
  `features` folds in and resolves docs/24 Q-features-003. `BuildInfo`
  ships from the parameters already flowing through the pipeline; the two
  `Option` fields wire up when a define source lands.

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
- Go `runtime/debug.ReadBuildInfo()` and Rust's `built` crate: the
  toolchain-provides-the-values `BuildInfo` prior art (§9.2, Q-BD-009).
- #5834 — the tracked JVM manifest version-hardcode bug surfaced in §9.1.
