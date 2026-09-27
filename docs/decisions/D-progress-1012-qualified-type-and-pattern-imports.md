# D-progress-1012 — Qualified type positions and pattern heads need a reachable import too

**Status:** shipped

Fixes #7548. Follow-up to D-progress-1011 (#7495/#7499), which fixed a
qualified *expression* path but explicitly scoped out type positions and
pattern heads:

> Type positions (`val c: Std.Rest.RestClient`) and pattern heads (`case
> Std.Rest.Kind.A ->`) resolve through their own paths and are not covered
> by this change.

## Problem

The same silent-acceptance gap D-progress-1011 closed for expression paths
still existed for these two positions, because both resolve a qualified
name through paths that never call `checkQualifiedPackageRef`:

```
package Other.Probe
func f(w: in Std.Rest.RestClient): Unit { ... }   // no import Std.Rest — typechecks
```

```
package Other.Probe
func f(k: in Std.Rest.Kind): Int {
  match k {
    case Std.Rest.Kind.A -> 1   // no import Std.Rest — typechecks
    case _ -> 0
  }
}
```

`Lyric.Pipeline` preloads every stdlib package's signatures regardless of
the file's imports (D-progress-1011's root cause #1), so both examples
"know about" `Std.Rest` and type-check cleanly with no diagnostic.

## Decision

**Type position.** `resolveTypePath` (`typechecker_resolver.l`)'s
multi-segment branch gets a new `checkQualifiedTypePackageRef`, run before
any lookup: when the qualifier names a package the checker loaded but the
package is neither the current package, `Std.Core`, nor reachable from the
file's own imports (`qualifiedPkgReachable`, factored out of
`checkQualifiedPackageRef` so both call sites share the one reachability
test), it reports T0020 with the exact message shape D-progress-1011
established, then the type resolves to `TyError`. A package-private type is
checked first and left alone here — `symbolToType` already calls
`checkImportedVisibility` for every type this path resolves to (the
pre-existing #1957 "multi segment private type rejected" test proves this),
so reporting T0097 here too would double it. Because `resolveType`
recurses uniformly for parameters, fields, return types, and generic type
arguments, one call site covers all of them.

**Pattern heads.** `unionCaseSymbolForScrutinee`'s tier A/B qualifier check
(#6287 Phase B) validates a qualified pattern head's SHAPE against the
scrutinee's own union/enum, not its reachability — a structural match
(`case Std.Rest.Kind.A ->` against a `Std.Rest.Kind`-typed scrutinee) says
nothing about whether `Std.Rest` is nameable from this file. Both the
`DKUnionCase` and `DKEnumCase` success arms now check
`scrCands[sci].originPackage` (the case's REAL declaring package — already
known once tier A/B has matched, rather than re-derived from the head's own
segments the way `checkQualifiedPackageRef` does for a `Pkg.Sub.func(...)`
call) against reachability, via a new shared reporter
(`reportUnimportedQualifiedPackage`) that takes the already-known package
name directly instead of a segment list: `pat2fnExpr` always flattens a
pattern head to one flat `EPath` regardless of depth, so — unlike a
qualified call, which reaches `checkQualifiedPackageRef` through a nested
`EMember` chain one segment-boundary at a time — there is no source-visible
seam separating a pattern head's package qualifier from its type name
qualifier without the scrutinee's own tier A/B match to supply it. Gated
identically on the same ordering as the type-position fix: a package-private
case is checked first (T0097, regardless of import) before the reachability
check (T0020), so an unimported private case still gets T0097. Both new
checks live strictly inside the tier A/B success branches, so the #6700
unresolvable-scrutinee fallback (which never enters tier A/B) is untouched.

## Scope

Record-pattern heads (`PRecord`'s own `head: ModulePath`) are **not**
covered: both places that type-check a `PRecord` pattern (`bindPatternTyped`,
`checkConstRefPattern`) discard the head entirely and resolve fields purely
from the scrutinee's type — there is no existing validation of the head at
all, qualified or not, import-reachable or not. Adding one is a separate,
larger structural-validation feature, not an import-reachability fix; left
for a follow-up.

A pre-existing, orthogonal gap was found while verifying the value-read half
of #7548 (`Lib.Net.Rest.someVal`/`Lib.Net.Rest.Kind.A` with no call): for a
**multi-package `[project.packages]` manifest build**, `--target dotnet`
silently accepts a plain qualified value read into a package the consuming
package never imports, while `--target jvm` correctly reports T0020 for the
identical source. Both targets share `Lyric.Pipeline`'s
`checkWithImportedPackages` entry point, and the single-file/`ImportedPackage`-
list harness this fix's own self-tests use resolves both cases identically
(confirmed: every #7495/#7499/#7548 self-test passes), so the divergence is
specific to how the MSIL project-build bridge assembles or consumes that
pipeline for a multi-package, single-assembly-output project — not to
anything `checkQualifiedPackageRef`/`resolveExprPath` do. Left open: the
root cause needs its own investigation of the MSIL project-build path,
which is a materially different piece of machinery from the type-checker
fix this entry covers, and risks regressing existing project builds if
patched without that investigation. The single- and multi-segment forms
WITH the import present (`Lib.Net.Rest.someVal`, `Lib.Rest.someVal`,
`Lib.Net.Rest.Kind.A`) build and run correctly on both targets — verified
directly, not merely inferred.
