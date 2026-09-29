# Module-level destructuring `val` binds every name (#7763, D144)

`registerItem` in `type_checker/typechecker_checker.l` registered a module
`val` only when its pattern was `PBinding(name, None)`, and the MSIL, JVM and
native backends likewise stored only single-name module values. The grammar's
`ValDecl` takes a pattern, so `package P\nval (a, b) = (1, 2)\nfunc f(): Int
{ b }` parsed, got no diagnostic at the declaration, and reported T0020
"unknown name" at every use; `val n is Int = 3` was dropped the same way.

Fix (D144): `Lyric.TypeChecker.desugarModuleValPatterns`
(`type_checker/typechecker_modval.l`) rewrites each destructuring module
`val` into single-name `val`s before anything indexes module values. It runs
in `pipeExpandAndRewrite`, so the checker, every backend and importing
sibling packages see the same items, and on entry to the checker for callers
outside the pipeline. A tuple pattern over a same-arity tuple literal binds
element by element; anything else is evaluated once into a
`__lyric_modval_<n>` module value and each name is a one-arm `match`
projecting it out. A tuple annotation is split across the names; the other
names get their checked types written on after checking
(`recordModuleValTypes` → `SymbolTable.moduleValTypes` →
`annotateModuleVals` in `pipeCheckAndMono`), without which MSIL typed the
projected static field as `object` (an `InvalidProgramException`-class
`StackUnexpected` in the `.cctor`, `null` for a `String` element).

A refutable pattern, or a tuple pattern the initializer's type cannot have
(`val (a, b) = five()`, `val (a, b) = (1, 2, 3)`), is the new **T0144**,
naming the form; it gates in the pipeline whether or not the type check is
fatal on that path, like T0080.

Verified by `module_val_destructure_self_test.l` (new, 7 cases, dual-target:
tuple literal, call initializer, nested + wildcard, annotated `(Int, Long)`,
`whole @ (first, second)` evaluated once, `pub`, a later module value reading
the names), added to both CI batch scripts: before the fix every case failed
to compile with T0020 on `--target dotnet` and `--target jvm`. Eight new
`typechecker_self_test.l` cases cover binding and typing, T0144 for each
refutable form and for shape mismatches, an importing package seeing `pub`
names (literal and call initializers), the desugared item shapes and
idempotence, and the recorded checked types. `ilverify` passes on the
compiled output; a two-package project using `pub val (pn, ps): (Int,
String) = pair()` runs on both targets; a literal-tuple destructuring runs on
`--target native`.
