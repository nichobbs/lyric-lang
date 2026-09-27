# 2026-09-27 — A0047 compares resolved types, not spellings

#7336.

`Lyric.Weaver`'s A0047 check (docs/56 / D115, a B′-mode template's
`where TArgs has { field: Type, ... }` row clause) compared a matched
function's parameter type against the row clause's declared type by
joining each side's written `TypeExpr` segments verbatim
(`bmodeTypeExprKey`). Instantiating `Lambda.Aspects.DeadlineGuard` (row
clause `where TArgs has { ctx: Lambda.LambdaContext }`) against a handler
declared `func guardedHandler(ctx: in LambdaContext)` — the unqualified
spelling, valid because the consumer file has `import Lambda` — falsely
rejected with A0047, even though both spellings name the same type.

Fixed by resolving each type name to the package that DECLARES it and
comparing the resolved names (`a0047TypeExprEqual` and its helpers in
`lyric-compiler/lyric/weaver/weaver.l`). The comparison walks both types in
parallel through generic arguments, slices, arrays, tuples, nullable types,
and function types, so `List[LambdaContext]` matches
`List[Lambda.LambdaContext]` element-wise.

Which package declares a name is not something the weaver can guess from
imports alone: a first version of this fix treated a bare name as any of
`Pkg.Name` for every whole-package import plus its bare spelling, so a row
clause `ctx: LambdaContext` under `import Lambda` matched a consumer's
`ctx: in LambdaContext` under an unrelated `import Timer` whose package
declares a different `LambdaContext` (review finding #7496). The weaver now
takes a type-owner index (`Lyric.Weaver.TypeOwnerIndex`: short type name ->
declaring packages, and each package's own imports), which
`Lyric.Pipeline.pipeTypeOwnerIndex` builds from the same `ImportedPackage`
lists the type checker resolves against. `pipeWeave` and
`Weaver.weaveFileWithDiagsAndTemplates` take the index; `pipeMiddleEnd` (the
JVM and native bridges) builds it from its `importedPkgs`; the MSIL
single-file path builds it from the stdlib packages, and the MSIL project
path from the stdlib and restored packages plus every bundle package and
path-dependency template source (`Weaver.typeOwnerIndexAddFile`).

A bare name resolves by the first rule that applies: a selector import
naming it (resolved as the qualified name); a primitive; a type the file's
own package declares; the one declaring package imported directly; the
`Std.Core` prelude; the one declaring package reachable through the imports'
own imports (so `List`, declared in `Std.CollectionsHost`, resolves through
`import Std.Collections`); and the only declaring package anywhere when
every package reachable from the file is indexed (`List` with no import). A
qualified `P.N` (after `import P as A` alias expansion) resolves to `P`, or
to the one declaring package reachable from `P` (`Std.Collections.List` is
`Std.CollectionsHost.List`), or stays as written. A name these rules cannot
pin to one package (unindexed, declared by two direct imports, several
reachable owners, or a lone owner behind an unindexed package) fails closed
to `<own package>.N`: two packages' same short name never compare equal,
while same-package references and identical qualified spellings still
match. Callers with no index (`weaveFile`, `weaveFileWithDiags`, used by
the verifier) get only those two.

The row clause's declared type resolves in the TEMPLATE's own file:
`Lyric.Weaver.CollectedTemplate` carries an `A0047Scope` (declaring package,
imports, and the type names that file declares), filled by
`collectAspectTemplates` at every call site in `lyric-compiler/msil/bridge.l`
and `lyric-compiler/jvm/bridge.l`. `resolveFromInstances` returns the origin
template for every resolved `from`-instance (keyed by the consumer's aspect
name), looked up once per aspect and reused for both the rewrite and the
origin map, so `buildBModeCallSite` resolves each side in its own file. A row
clause declared in the woven file itself resolves both sides in that file.

Weaver self-tests in `lyric-compiler/lyric/weaver_self_test.l` build a
fixture index from package sources (`makeTypeIndex`) and cover: an
unqualified consumer spelling accepted, a qualified spelling accepted, an
aliased-import spelling accepted, the same short name from a different
package rejected, generic-argument resolution, the #7496 case (bare
`LambdaContext` under `import Lambda` vs. under `import Timer`) rejected, the
same bare name under the same import accepted, bare `List` with and without
`import Std.Collections` on either side accepted, `Std.Collections.List`
resolved through the re-export, a same-package bare type on both sides
accepted, and an unindexed short name in two packages rejected.
`lyric-lambda/tests/lambda_aspect_weaving_tests.l`'s `guardedHandler` /
`misconfiguredHandler` declare `ctx: in LambdaContext` (unqualified)
instead of the `Lambda.LambdaContext` workaround, exercising the fix
end-to-end against the real `Lambda.Aspects.DeadlineGuard` template.
