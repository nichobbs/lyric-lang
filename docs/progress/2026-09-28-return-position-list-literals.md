# Type checker: bracket-literal List[T] direct typing extends to return position, resolved by id not name (#7696, D-progress-1026)

D-progress-1025 (#7545) made a bracket literal (`[...]`) type directly as
`List[T]` — instead of the default `slice[T]` — at every position where a
`List[T]` is expected, except one it explicitly carved out: return
position. `return [1, 2, 3]` against a declared `List[Int]` return type
still required an explicit `.toList()`, because `SReturn`'s check routed
the returned expression through `typeAssignable` against its own
already-inferred type, never through the expected-type-aware
`inferExprExpected` the other positions use. The same gap applied to a
block's trailing/implicit value, an expression-bodied function's `= [...]`
body, and an `if`/`match` arm whose value becomes any of those — all
surprising given every OTHER `List[T]`-expected position (a binding, a
constructor field, a call argument) already accepted the identical literal
with no conversion needed.

The fix threads a new `tailExpected` parameter through `checkBlock`,
`inferIfExpr`, `inferMatchExpr`, and `inferExprOrBlock`
(`lyric-compiler/lyric/type_checker/typechecker_{exprs,stmts}.l`), kept
deliberately separate from the pre-existing `returnTy` parameter those
functions already carry for checking `return` statements. `tailExpected`
carries the enclosing function's declared return type only when a block's
trailing value (or an `if`/`match` arm's value) is genuinely, structurally
part of that function's own return-value chain — the top-level function
body, or a same-chain continuation (`{ }`/`unsafe { }`/`try`/`if`/`match`
in tail position) — and is `TyError` ("no expectation") everywhere else: a
loop/catch/finally body, a lambda body, or an `if`/`match`/`{ }` reached as
an ordinary subexpression via `inferExpr`'s generic dispatch (e.g. a
binding initialiser). This scoping matters: an untyped
`val x = if c { [1, 2, 3] } else { [4, 5, 6] }` must keep inferring
`x : slice[T]` even when the enclosing function happens to also return
`List[Int]` for unrelated reasons, since codegen at THAT call site has no
surrounding declared-type context to build `List[T]` from. `checkStatement`'s
`SReturn` case and `checkFunctionBody`'s `FBExpr` case now call
`inferExprExpected` directly with the function's declared return type.

Separately (found while extending the same code), both of D-progress-1025's
own literal-typing call sites (`inferExprExpected`'s `EList` arm and
`listLiteralArgSatisfiesParam`) matched the expected type by its bare name
(`ename == "List"`), not by `List`'s `TypeId` the way `.toList()`'s own
resolution already does (`stdCollectionsListTypeId`, #7665). A package
declaring its own unrelated `record List[T]` — never importing
`Std.Collections` — also intercepted a bracket literal at every one of
those positions, and both backends' codegen unconditionally builds the
GENUINE stdlib collection there regardless of what the checker resolved
"List" to — the exact checker/codegen split #7665 fixed for `.toList()`,
reopened for the literal-typing arms D-progress-1025 introduced. Both call
sites now resolve `List[T]` by `stdCollectionsListTypeId(tbl)` instead.

No MSIL or JVM codegen change was needed for either fix. MSIL's `SReturn`
and function-tail lowering already push the declared return type onto
`collExpect` before lowering the returned/tail expression (pre-existing,
#2289/#4965), a scope that already covers nested `if`/`match` tail
branches, so the checker agreeing the expression IS `List[T]` was
sufficient for the existing `EList` codegen arm to build a genuine
`List<T>`. JVM's `EList` codegen builds a `java/util/ArrayList`
unconditionally regardless of context, which already matches `List[T]`'s
own JVM representation.

See D-progress-1026 for the full design rationale and scope notes.
`docs/01-language-reference.md` §2.7 gained the return-position and
id-based-resolution language. `lyric-compiler/lyric/typechecker_self_test.l`
gained cases for: literal direct-typing via explicit `return`, a block's
trailing value, an expression-bodied function, and both `if` and bare-expr
`match` arms; a `slice[T]` VALUE still rejected at each of those same
positions; a user-defined `record List[T]` no longer accepting a bracket
literal as if it were `Std.Collections.List`; the "slice-typed value
rejected on assignment to a List[T]-typed var" test's assertion corrected
from `T0060 or T0063` to the precise codes that source actually raises
(`T0061` — the var-binding code, since the source declares with `var`, not
`val` — and `T0063` for the following plain assignment); and the
pre-existing `.toList()`/binding/ctor-field/call-argument literal-typing
tests migrated to a real `Std.CollectionsHost` import so the id-based gate
has a genuine stdlib `List` to resolve against.
`lyric-compiler/lyric/return_list_literal_self_test.l` is a new dual-target
runtime self-test: it compiles real functions returning list literals
through the actual self-hosted MSIL and JVM backends and asserts on the
resulting runtime values (count, elements, and that `.add` still works —
proving a genuine `List<T>`/`ArrayList` was built), wired into
`scripts/ci/compiler-self-tests-batch.sh` (dotnet) and
`scripts/ci/jvm-generics-self-tests-batch.sh` (jvm).

`make self-test NAME=typechecker` (608/608),
`scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh`,
`scripts/ci/native-backend-self-tests.sh`,
`scripts/ci/jvm-ecosystem-suites.sh`, and `lyric test --manifest` for every
`lyric-*/lyric.toml` and `examples/*/lyric.toml` on `--target dotnet` all
pass with zero regressions.
