# D-progress-1011 — Qualified paths need a reachable import; private type receivers are T0097

**Status:** shipped

Fixes #7495 and #7499. Follow-up to D-progress-1001 (#7345).

## Problem

Two call shapes type-checked cleanly although docs/01 §9.2 and §3.1 make
both of them errors:

```
package Other.Probe
func main(): Unit {
  val c = Std.Rest.RestClient.create("http://127.0.0.1:1/api")   // no import Std.Rest
}
```

```
package Lib
opaque type Widget { name: String }            // package-private
pub func Widget.create(name: in String): Widget { Widget(name = name) }

package App
import Lib
func f(): Unit { val w = Widget.create("x") }  // accepted
```

What happened next depended on the backend rather than on the language
rules. Against a single-file `lyric run`, the unimported qualified call ran
on MSIL (the stdlib bundle happens to contain `Std.Rest`) and failed in JVM
codegen with `J008 reference 'Std' resolves to no local, parameter, …`; the
private receiver in a single-output project ran on both. Whether a program
builds must not depend on which packages the pipeline happened to load or
bundle.

The JVM `J008` also fired for the *imported* multi-segment form
(`import Std.Rest` + `Std.Rest.RestClient.create(url)`), a separate parity
gap fixed here too (below).

## Root cause

1. `Lyric.Pipeline` loads every stdlib package's signatures whatever the
   file imports, so the #6361 T0020 gate for a qualified `EPath`
   (`symTablePackageHasAnySymbol`) sees `Std.Rest` as known. The alias
   rewriter only collapses a qualifier that is an import alias, so an
   unimported `Std.Rest.RestClient.create(...)` stays an `EMember` chain
   rooted at `EPath(["Std"])`; `Std` is not a symbol, the chain types as
   `TyError`, and D-progress-1001's `checkUnimportedTypeReceiver` (which
   only looks at a bare single-segment receiver) never sees it. Codegen
   resolves calls through the file's own import closure, so the call does
   not link.
2. `checkUnimportedTypeReceiver` returned early whenever the type's package
   was reachable, and otherwise reported only when the type had a
   visibility modifier. A package-private receiver type therefore got no
   diagnostic in either case, and `resolveExprPath` runs visibility
   (`checkImportedVisibility`, T0097) only for value symbols; the receiver
   is inferred through a discarded scratch diagnostic list anyway.

## Decision

**A package-qualified path may not name a package outside the file's
import closure.** docs/01 §9.2 already states that, apart from the
`Std.Core` prelude, every name must be reachable from the file's own
imports; qualification says *which* package a name comes from, it is not
a second way to bring a package into scope. Making codegen resolve against
every loaded package instead was rejected: it would make a file's
dependencies depend on what the pipeline happened to load (the whole
stdlib for signatures, only the import closure for linking), and would
make the `import` list stop describing the file's dependencies.

`checkQualifiedPackageRef` (`typechecker_exprs.l`) runs on every qualified
reference: from the `EMember` arm (a qualifier left as a chain), from the
`ECall` arm (a qualified callee, which never passes through the `EMember`
arm), and from `resolveExprPath`'s multi-segment branch (a qualifier the
alias rewriter collapsed). When the qualifier is a package the checker
loaded, is not the current package or `Std.Core`, and is not reachable by
the same transitive walk D-progress-1001 uses (`symTableImportReachable`,
with a direct-import fast path), it reports **T0020**: `unknown name
'Std.Rest.RestClient' (package Std.Rest is not imported; add import
Std.Rest)`. It never fires when the chain's root is a local or a symbol in
scope (a value's field chain that spells a package name), for a qualifier
that is not a loaded Lyric package (auto-FFI host paths such as
`System.Console`), or with no package scope set (`curPkg == ""`). A
diagnostic reached from two of these entry points is emitted once.

**A package-private type used as a call receiver from another package is
T0097, not T0020**, whether or not the declaring package is imported:
adding an import cannot make the type nameable. The bare form
(`Widget.create(...)`, in `checkUnimportedTypeReceiver`) and the qualified
form (`Lib.Widget.create(...)`, in `checkQualifiedPackageRef`) both report
it; extern-type bindings stay exempt as they are from every visibility
tier (docs/01 §3.1).

**A `pub` type-associated function on a package-private type is not an
error at its declaration.** Its reach is capped by its receiver type's
visibility, the same way a `pub` function's signature may already mention
a package-private type with no declaration-site diagnostic; the use-site
T0097 is the enforcement point docs/01 §3.1 prescribes ("visibility is
enforced at use sites"). A declaration-site lint would belong to a general
"package-private type in a `pub` surface" rule, which would cover this
case and the signature case together; no such pattern exists anywhere in
the compiler, stdlib, or ecosystem libraries today.

## JVM: imported multi-segment qualified receivers

`Lyric.AliasRewriter` collapses a qualified call's callee chain into a flat
`EPath` only when the whole receiver is an import key (`Std.Rest.ping()`).
A type-associated function reached through a multi-segment package
(`Std.Rest.RestClient.create(url)`) has a receiver one member past the
package path, so it stayed a nested `EMember` chain rooted at
`EPath(["Std"])`; MSIL codegen tolerated that, JVM codegen treated `Std` as
a value and failed. `rewriteQualifiedReceiverChain` now rewrites the
receiver to the flat `EPath` `Std.Rest.RestClient` when the qualifier
prefix is an import key in its entirety — the shape the depth-1 `EMember`
arm already gives a single-segment package's `Lib.Widget.create(...)`,
which both backends lower. Like the existing collapse it applies only in
call-callee position and uses the shadow-filtered alias list, so a local
whose name matches the package root is left alone.

## Scope

Type positions (`val c: Std.Rest.RestClient`) and pattern heads
(`case Std.Rest.Kind.A ->`) resolve through their own paths and are not
covered by this change.
