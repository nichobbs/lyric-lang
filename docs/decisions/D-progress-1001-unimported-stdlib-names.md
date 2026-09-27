# D-progress-1001 — Unimported stdlib type as a call receiver is T0020

**Status:** shipped

Fixes #7345.

## Problem

```
package Other.Probe
import Std.Core
func main(): Unit {
  val c = RestClient.create("http://127.0.0.1:1/api")   // no `import Std.Rest`
  println("made")
}
```

`lyric build` accepted this with no diagnostic. At run time: MSIL threw
`System.Exception: unsupported method 'create' on the receiver type at this
call site (no matching user method, extern binding, or built-in intrinsic)`;
JVM threw `NoClassDefFoundError` naming the type under the *calling*
package. A name nothing declares at all (`TotallyUnknownThing.create("x")`)
was already rejected at compile time (T0115), so the gap was specific to a
type that exists in some other loaded package.

## Root cause

`RestClient.create(url)` parses as `ECall(EMember(EPath(["RestClient"]),
"create"), [url])` — a call whose receiver is a bare, uppercase-starting
type name, not a value (the docs/49 dotted type-associated-function
convention: `pub func RestClient.create(...)` desugars to nothing more than
an ordinary function named `RestClient.create`). `typechecker_exprs.l`
already treats such a receiver leniently on purpose: `resolveExprPath`
returns `TyError` for a type-name reference with **no diagnostic** (a type
name is never itself a value; the actual call is resolved later, by
codegen, not the type checker), and the call sites that infer this specific
receiver shape (`EMember(EPath([Name]), member)` where `Name` starts
uppercase) route that inference through a scratch diagnostic list that gets
thrown away entirely, so even a genuine unknown name was silently absorbed
at this one call shape.

Codegen resolves the *actual* function by walking the file's own import
closure (`Msil.Codegen.lowerMethodCallMsil`'s "type-associated function
call through an imported type" fallback, and the JVM analog): when
`Std.Rest` is imported, `RestClient.create` is found and a direct call is
emitted; when it is not, codegen falls through to the generic unresolved-
method-dispatch stub, which emits a runtime throw instead of failing the
build. Each backend only sees the file's own imports, so whether the call
resolves depends on information the type checker never consulted for this
receiver shape.

This is a narrower instance of the general tier-3 permissiveness in
`symTableTryFindOne` that #6287 documented and deliberately left alone (a
full "reject unimported resolution" rewrite there broke the stdlib's
implicit `Std.Core` prelude convention and the kernel/host re-export idiom
tree-wide — see that function's doc comment and #6703). This fix does not
touch `symTableTryFindOne`; it adds a targeted, additive check at the one
receiver shape the leniency swallows a real diagnostic for.

## Decision

Add `checkUnimportedTypeReceiver` (`typechecker_exprs.l`), called from both
sites that infer a bare uppercase-starting single-segment `EPath` receiver
in `EMember` position (the call form, `Type.method(...)`, and the plain
member form, e.g. an enum case access or a function-value reference). It:

1. Skips if the name is bound as a local (a real local always wins).
2. Resolves the name via the existing (unchanged) `symTableTryFindOne`. If
   nothing is found, or the symbol is not a type-kind declaration, it is a
   no-op (an unresolvable name here still reaches its ordinary fallback
   paths unchanged; a resolvable non-type name — a function, `val`, union
   case — is untouched).
3. Skips if the type is declared in the current package, or in `Std.Core`
   (the implicit prelude — `Option`/`Result` are referenced tree-wide with
   no `import Std.Core` at all, predating scoped resolution, #6287).
4. Skips if the type's declaring package is reachable from the current
   package by following declared `import`s **transitively**
   (`symTableImportReachable`, a BFS over `Lyric.TypeChecker`'s existing
   per-package `packageImports` index). This closes the kernel/host
   re-export gap #6287 flagged as blocking a broader fix: a file that
   imports `Std.Collections` never itself imports `Std.CollectionsHost`
   (where `List`/`Map` are actually declared), but `Std.Collections`'s own
   source does, so the walk finds it.
5. Otherwise, and only when the type is cross-package-visible (`pub`/
   `internal`), emits **T0020**: `unknown name 'RestClient' (declared in
   Std.Rest; add `import Std.Rest`)`.

A check running with no package scope at all (`curPkg == ""` — a
synthesised contract-surface check, or the flat historical
`checkWithImports` shim) never diagnoses: it has no import list to test
reachability against, and diagnosing there would be a false positive by
construction.

This is purely additive: every call the checker already accepted (same-
package, directly imported, transitively re-exported, or `Std.Core`) type-
checks exactly as before. Only the previously-silent "resolves to a type,
but that type's package is unreachable from this file" case gains a
diagnostic.

## Backend runtime fallbacks

Both backends' "unresolved static/method call" runtime-throw stubs
(MSIL's generic "unsupported method" stub in `lowerMethodCallMsil`; the JVM
analog) remain **unchanged and reachable**. They are not specific to this
bug: the same stub is the general fallback for a call whose receiver's
concrete runtime type cannot be established statically at all (an erased
generic receiver, a value flowing through `object`, …) — turning it into a
compile-time error would reject legitimate programs that rely on dynamic
dispatch reaching an unreachable branch only in theory. For the exact
shape this issue reports — a bare type-name receiver, unimported — the type
checker's new T0020 now runs first and the call never reaches codegen, so
the runtime stub is unreachable for *this* shape specifically, without
narrowing what it still legitimately covers.

## Scope not covered

A **fully package-qualified** call to the same unimported function
(`Std.Rest.RestClient.create(url)`, no `import Std.Rest` at all) still
type-checks with no diagnostic today: `Lyric.Pipeline` loads the whole
stdlib's signatures regardless of the file's own `import` list (so
`symTablePackageHasAnySymbol`/`symTablePackageHasMember` — the #6361 T0020
gate for a qualified `EPath` — see the package as "known" independent of any
import), and the AliasRewriter's alias table has no entry for an
unimported package, so the multi-segment `EMember` chain reaches a
different, unaudited code path than the bare-receiver shape this fix
targets. This is tracked in #7495, which covers extending the same
reachability check to qualified chains.

## Newly surfaced fixes

None: the new diagnostic did not surface a genuine unimported-type-as-
call-receiver reliance anywhere in the compiler, stdlib, or ecosystem
during the full-tree build and test pass this change was verified against
(all 483 `typechecker_self_test.l` cases, the full dotnet stdlib runtime
suite list, and `lyric test` across every ecosystem library matched
baseline exactly, `lyric-mcp` and `hash_tests` aside — both were pre-
existing baseline failures caused by a stale binary/unresolved-restore
state in the comparison checkout, not by this change; both pass cleanly
against a freshly built `./bin/lyric`).
