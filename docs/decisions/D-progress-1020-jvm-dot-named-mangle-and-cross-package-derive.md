# D-progress-1020 — JVM dot-named method mangling and cross-package derive signatures (#7501, #7502)

**Status:** shipped

Fixes #7501, #7502. Follows on from D-progress-1002, which documented both
gaps as the reason `json_generate_tests.l` ran on `--target dotnet` only.

## Problem

The JVM backend emits every dot-named function (`func TypeName.member(...)`,
written by hand or synthesised by `@derive`/`@generate`) as a `public static`
method on its declaring package's shared host class, and — before this
change — named the classfile method after the bare member name alone
(`lowerFuncScoped` stripped the `"TypeName."` prefix off `decl.name`). Two
different types in the same package declaring a same-named member with the
same parameter list therefore collided on one bare name and descriptor:
`java.lang.ClassFormatError: Duplicate method name ... with signature` at
class-load time (#7501). Any package with two `@generate(Json)` records hit
this immediately (both synthesise `fromJson(String)` and
`fromJsonElement(JsonElement)`), which in turn meant nested
`@generate(Json)` decoding never worked on the JVM at all, since nesting
needs two records.

Separately, `Jvm.Bridge.collectDeriveFreeSigs` — which registers a
derive-synthesised dot-named function's signature into the cross-package
call registry, since the earlier `collectFileSigsSeeded` pass runs on the
PRE-derive file and never sees them — only ever ran for the CURRENT
package being compiled. A call from a different package to one of its
derive-synthesised functions (`Person.fromJson(body)` with `Person` imported
from another project package) fell through to the erased auto-FFI guess and
failed with `auto-FFI: class 'Xp.Api.Person' not found` (#7502). Separately,
`collectDeriveFreeSigs` also never eagerly resolved a derive-synthesised
function's declared return-type generic args against its own declaring
package/extern scope — the treatment every other free-function registration
already gets (`Jvm.Codegen.eagerlyResolveGenericArgs`) — so even a call that
DID resolve left the decoded `Result[T, String]`'s `Ok` payload erased
unless the caller added an explicit type annotation.

## Decision

### Name mangling (#7501)

A dot-named function that lives on its package's shared host class is
named `TypeName$member` in the classfile — the same `$` separator this
backend already uses for a union case's nested class name (`Type$Case`).
Every such function is mangled, not just on an actual collision: this keeps
the scheme simple and collision-proof rather than requiring a separate
collision-detection pass.

A **synthesised per-type static** — a distinct/range-subtype's
`from`/`tryFrom` conversion, or a `wire` factory's static accessor — is
resolved through the SAME dot-named lookup keys (`Type.tryFrom(x)`,
`AppWire.bootstrap()`), but each lives on its OWN dedicated class
(`<package>/<TypeName>`, or the wire's own generated class), never the
shared host class, so it needs no mangling and keeps its plain method name.

**Disambiguation is resolved at REGISTRATION time, not guessed at the call
site.** An earlier draft of this fix told the two cases apart at each call
site by comparing the resolved signature's `owner` class (or, where only a
simple class name was available, its simple name) against the receiver's own
type name / the call's package prefix. That comparison is exact for a
package-qualified call and for the derive-instance-method call shape, but at
the single-segment unqualified form (`Widget.make()`, no package prefix in
the call syntax) it degenerates to comparing `jvmSimpleName(sig.owner)`
against the receiver's type name — which is WRONG whenever a package's own
last dotted path segment happens to be spelled the same as a type it
declares (e.g. package `P.Widget` declaring `record Widget`): a plain
dot-named function on the shared package class then looks, by that
comparison alone, indistinguishable from a per-type static, and the call
site would wrongly skip the mangle — a genuine, if narrow, silent-miscompile
risk this project's production-readiness standard does not accept, however
rare the triggering shape.

The shipped fix instead adds `JvmFuncSig.jvmMethodName: String` — the EXACT
classfile method name a call site must `invoke*`, set once by whichever
`JvmFuncSig` construction site minted this signature's actual emitted
method, never recomputed or guessed downstream:

- A dot-named IFunc registration (`collectFileSigsSeeded`'s `IFunc` arm,
  `Jvm.Bridge.collectDeriveFreeSigs`, and `collectMonoSpecializedSigs` — a
  monomorphized copy of a GENERIC dot-named function keeps its `"TypeName."`
  prefix, e.g. `Type.method__Int`, and needs the same mangle) computes
  `jvmDotMethodName(typeName, memberName)` via the new
  `Jvm.Codegen.jvmDotMethodNameFromDeclName` helper.
- A synthesised per-type static (distinct/range-subtype `from`/`tryFrom`, a
  wire factory accessor) and every non-dot-named registration (instance/
  interface methods, module vals, enum cases, opaque/record field
  pseudo-keys, projectable `toView`/`tryInto`, aspect-woven/B′-mode
  specialisations) records its own already-correct plain name.

Every call site that resolves a dot-named function
(`lowerMethodCall`'s `qualifiedDotNamedSigJvm`-caller arm, its single-segment
"distinct dot key" fallback, and the derive-instance-method-shaped call)
now simply invokes `sig.jvmMethodName` — no owner/receiver-name comparison
of any kind remains in `lyric-compiler/jvm/codegen/04_calls.l`. This makes
the disambiguation exact for every case, including the package/type-name
coincidence described above, since the definition site always knows which
kind of function it minted; a call site never needs to reconstruct that
fact from indirect signals.

Because this touches the shared `JvmFuncSig` record (a JVM-codegen
convention: no defaulted field survives the F# stage-0 seed, so every field
is passed explicitly at every construction site — same discipline
`isIface`/`retGenericArgs`/`recordRetClass` already observe), all 18
`JvmFuncSig` construction sites across `lyric-compiler/jvm/codegen/01_types.l`,
`06_items.l` and `lyric-compiler/jvm/bridge.l` set `jvmMethodName` explicitly.

`lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l` (new)
pins the exact false-positive shape the rejected heuristic would have
miscompiled: package `P.Widget` (host class `P/Widget`, simple name
`Widget`) declares `record Widget` and `func Widget.make(...)`, plus an
unrelated free `func make()` — under the rejected heuristic both would have
kept the bare classfile name `make` on the shared `P/Widget` class
(`ClassFormatError: Duplicate method name`); the shipped fix mangles
`Widget.make` to `Widget$make` regardless of the package/type-name
coincidence. The same file also exercises a genuine per-type static
(`Age.tryFrom`, a distinct type declared in the same package) to confirm it
still resolves correctly, un-mangled.

### Cross-package derive signatures (#7502)

`Jvm.Bridge`'s compile driver pre-registers every bundled/sibling package's
derive-synthesised dot-named signatures via a plain
`Lyric.Derives.deriveFile` pass (not the full middle-end pipeline) BEFORE
the user's own entry package is codegen'd. This is necessary, not just
convenient: the existing `toBundle` compile loop (which already called
`collectDeriveFreeSigs` on each sibling's fully-middle-ended file, once per
sibling, in compile order) runs strictly AFTER the user's entry package's
own `codegenPackageInto` call — so a call FROM the entry package INTO a
sibling's derive-synthesised function was still unregistered at the moment
the entry package's own call site needed to resolve it, even once that
sibling was later compiled. A derive-synthesised function's declared
signature comes entirely from its own record's field types, needing no
cross-package type-check context, so the lightweight `deriveFile` pass is
sufficient for correct SIGNATURE registration; the later, full-pipeline
`collectDeriveFreeSigs` call inside the `toBundle` loop still runs
afterwards (for the function BODY's bytecode) and is a no-op there thanks to
`collectDeriveFreeSigs`'s own first-wins `into.containsKey` guards.

`collectDeriveFreeSigs`'s `retGenericArgs` field is now computed with
`Jvm.Codegen.eagerlyResolveGenericArgs`, exactly like the plain
free-function registration in `collectFileSigsSeeded` already does — a bare
`TRef` naming, say, the record itself inside its own `Result[TypeName,
String]` return is rewritten to the fully package-qualified JVM class name
at REGISTRATION time, so a consumer package's call site needs no
declaring-file context to recover it. Without this, `val p = Person.
fromJson(body)` followed by a SEPARATE `match p { case Ok(x) -> x.field }`
left `x` erased to `Object` on the JVM (a J007 diagnostic) unless the
caller added an explicit `: Result[Person, String]` annotation — a match
arm binding straight off the call expression (`match Person.fromJson(...) {
case Ok(x) -> ... }`) was unaffected, since that shape is narrowed through
the case-class `paramIdx` payload-unboxing mechanism instead.

## Verified

- `lyric-compiler/jvm/derive_dot_name_mangle_jvm_self_test.l` (new,
  `@test_module`, wired into `scripts/ci/jvm-generics-self-tests-batch.sh`):
  two `@generate(Json)` records in one package, nested decode through
  `fromJsonElement`, a third record decoded on its own, two hand-written
  dot-named functions with an identical parameter list on two different
  types, an unannotated `Result` binding narrowed through a separate
  `match` + field read, and the existing malformed-nested-JSON error
  message unchanged.
- `lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l` (new,
  wired into `scripts/ci/jvm-generics-self-tests-batch.sh`): the
  package/type-name-coincidence false positive described above, plus a
  genuine per-type static in the same package.
- `scripts/ci/derive-json-cross-package-jvm-e2e.sh` (new, invoked from
  `scripts/ci/compiler-self-tests-batch.sh`, same precedent as
  `project-package-import-reachability-e2e.sh`): a two-project-package
  build (`Xp.Api` declaring the `@generate(Json)` records, `App` importing
  it and calling `Person.fromJson(body)` with no type annotation), both
  `--target dotnet` and `--target jvm`.
- `lyric-stdlib/tests/json_generate_tests.l` now runs on `--target jvm` too
  (`scripts/ci/json-generate-jvm-test.sh`, invoked from ci.yml — the file
  is near GitHub's undocumented workflow-size ceiling,
  `scripts/ci/check-workflow-size.sh`), alongside its existing
  `--target dotnet` run; unmodified pass on both targets.
- `lyric-stdlib/tests/json_tests.l` (single `@generate(Json)` record, the
  pre-existing baseline) still passes on both targets — no regression.
- `scripts/ci/compiler-self-tests-batch.sh`, `scripts/ci/jvm-generics-self-
  tests-batch.sh` (0 `not ok`), and `scripts/ci/jvm-ecosystem-suites.sh` all
  pass with these changes in place.

## Known gap found, left out of scope

`Jvm.Codegen.scrutineeGenericArgs` has no `EPropagate` (`?`) arm: `val p =
someCall(...)?` never records `p`'s recovered instantiation, so a LATER
field/method read on the unannotated binding still fails with J007. This is
a general `?`-propagation gap, not specific to `@generate(Json)` or to
either #7501/#7502, and reproduces identically for a hand-written
`Result`-returning function. Tracked separately as #7630.
