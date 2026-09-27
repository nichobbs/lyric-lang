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

Fixed by resolving each side's type expression against its own file's
imports before comparing (`Lyric.Weaver.a0047CanonicalTypeKey` and its
helpers, `lyric-compiler/lyric/weaver/weaver.l`): a multi-segment path is
already package-qualified unless its first segment names an
`import X as A` alias in scope (expanded to `X`'s own path first); a bare
single-segment name is resolved against a selector import
(`import Pkg.{Foo}` / `import Pkg.{Foo as Bar}`) first, then against every
selector-less import (`import Pkg`, aliased or not — both bring `Pkg`'s
public names into unqualified scope), and falls back to the bare name
itself when no import resolves it (a same-package local type, or a
no-import-needed prelude type such as `String`/`List`/`Option` — this
preserves the pre-fix comparison for that case instead of guessing an
owning package, which would make every cross-package `List[...]` /
`Option[...]` row-clause field spuriously mismatch). Resolution recurses
through generic arguments, slices, arrays, tuples, nullable types, and
function types, so `List[LambdaContext]` matches
`List[Lambda.LambdaContext]` element-wise. A bare name that resolves to
two or more distinct packages across a file's imports is genuinely
ambiguous and resolves to a sentinel that can never equal a real
fully-qualified name, so the check fails closed to A0047 rather than risk
accepting two different types that merely share a short name (`A.Ctx` vs.
`B.Ctx`).

The row clause's declared type is normalised against the TEMPLATE's own
declaring package's imports, not the consumer's: `Lyric.Weaver.CollectedTemplate`
now carries the declaring file's `imports` (threaded through
`collectAspectTemplates`'s six production call sites in
`lyric-compiler/msil/bridge.l` and `lyric-compiler/jvm/bridge.l`, plus the
self-test's), and `resolveFromInstances` returns the origin
`CollectedTemplate` for every resolved `from`-instance (keyed by the
consumer's aspect name) alongside the rewritten items, so
`buildBModeCallSite`'s row-type check can look up the right import context
per aspect. A `from`-instance with no recorded origin (the row clause was
declared directly in the same file being woven) falls back to that file's
own imports for both sides, which is correct since template and consumer
are the same file in that case.

Five new weaver self-tests in `lyric-compiler/lyric/weaver_self_test.l`
cover: an unqualified consumer spelling accepted, a qualified spelling
accepted, an aliased-import spelling accepted, the same short name
resolved from a different package still rejected, and generic-argument
normalisation (`List[LambdaContext]` vs. `List[Lambda.LambdaContext]`).
`lyric-lambda/tests/lambda_aspect_weaving_tests.l`'s `guardedHandler` /
`misconfiguredHandler` now declare `ctx: in LambdaContext` (unqualified)
instead of the `Lambda.LambdaContext` workaround, exercising the fix
end-to-end against the real `Lambda.Aspects.DeadlineGuard` template.
