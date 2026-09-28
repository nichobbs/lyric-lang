# D-progress-1026 — Type checker: bracket-literal `List[T]` direct typing extends to return position; `List` resolved by id, not name (#7696)

**Status:** shipped

**Context.** D-progress-1025 (#7545) made a bracket literal (`[...]`) type
directly as `List[T]` — instead of the default `slice[T]` — whenever it is
used directly where a `List[T]` is expected: a `val`/`var`/`let` binding, a
constructor field argument, or an ordinary call argument. Its own "Scope
note" explicitly carved return position out: `return [1, 2, 3]` against a
`List[T]`-declared return type kept requiring an explicit `.toList()`,
because a return checks the returned expression through `typeAssignable`
(against the ALREADY-INFERRED type of the expression), not through the
expected-type-aware `inferExprExpected` the other four positions route
through.

This split was surprising in practice (#7696): every other position where a
`List[T]` is expected accepts a bare bracket literal, but the single most
common shape for building a fresh list — a function that constructs and
returns one — did not, `func f(): List[Int] { [1, 2, 3] }` and
`func f(): List[Int] = [1, 2]` both still required `.toList()` for no
reason a user could discover from the language reference. The same gap
applied one level down: `if`/`match` used as a function's tail value, and a
`return` nested inside either arm.

Separately, #7696 found that both of D-progress-1025's own literal-typing
call sites (`inferExprExpected`'s `EList` arm, and
`listLiteralArgSatisfiesParam`) matched the expected type by its BARE NAME
(`ename == "List" and eargs.count == 1`), not by `List`'s `TypeId` the way
`.toList()`'s own resolution already does (`stdCollectionsListTypeId`,
D-progress-1025's own precedent citation, #7665). That meant a package
declaring its own unrelated `record List[T]` — never importing
`Std.Collections` — also intercepted a bracket literal at every one of
those four positions, and both backends' codegen (`collExpectTop`/
`MConcreteList` on MSIL, the ArrayList-by-default JVM literal path)
unconditionally builds the GENUINE stdlib collection there regardless of
what the checker resolved "List" to — the exact checker/codegen split
D-progress-1025's own citation (#7665) fixed for `.toList()`, reopened for
the literal-typing arms it introduced.

**Decision.**

1. **Return position now matches every other `List[T]`-expected position.**
   A bracket literal types (and is built) directly as `List[T]` in:
   - an explicit `return [...]` (`checkStatement`'s `SReturn` case, now
     routed through `inferExprExpected(sc, tbl, sigs, diag, e, returnTy)`
     instead of a bare `inferExpr`);
   - a block's trailing/implicit value, when that block is genuinely part
     of the enclosing function's return-value chain (`checkFunctionBody`'s
     `FBBlock` case, and `checkBlock`'s own trailing-statement dispatch);
   - an expression-bodied function's `= [...]` body (`checkFunctionBody`'s
     `FBExpr` case); and
   - an `if`/`match` arm whose value flows into any of the three positions
     above (`inferIfExpr`/`inferMatchExpr`/`inferExprOrBlock`, threading a
     new `tailExpected` parameter).

   `tailExpected` is deliberately a SEPARATE signal from the pre-existing
   `returnTy` parameter those functions already carry (which remains scoped
   to checking `return` statements against the function's declared type,
   regardless of nesting depth). `tailExpected` is `TyError` ("no
   expectation") everywhere the trailing value is NOT structurally,
   unambiguously the function's own return value — a loop/catch/finally
   body, a lambda body, or an `if`/`match`/`{ }` used as an ordinary
   subexpression (e.g. a binding initialiser) reached through `inferExpr`'s
   generic dispatch. This scoping matters: an untyped `val x = if c {
   [1, 2, 3] } else { [4, 5, 6] }` must keep inferring `x : slice[T]`
   exactly as before, even when the ENCLOSING function happens to also
   return `List[Int]` for unrelated reasons — using that coincidental
   match would let the checker accept a representation codegen has no
   surrounding declared-type context to build at THAT call site (codegen's
   `collExpectTop`/ArrayList-by-default paths only see the position's own
   immediate context, never an unrelated enclosing function's return type).

   A genuine `slice[T]`-typed VALUE (not a literal) is still rejected at
   every one of these positions — this entry only widens which POSITIONS a
   LITERAL types directly against, not D-progress-1025's removal of the
   value-level slice-satisfies-List exemption.

2. **`List[T]` direct-typing is now resolved by `TypeId`, not by name.**
   Both `inferExprExpected`'s `EList` arm and `listLiteralArgSatisfiesParam`
   now check the expected type's id against `stdCollectionsListTypeId(tbl)`
   (the same `Std.CollectionsHost`-owned lookup `.toList()` already uses,
   #7665) instead of `ename == "List"`. A package's own same-named
   `record List[T]` no longer accepts a bracket literal as if it were the
   real stdlib collection — a bracket literal cannot construct an arbitrary
   user record anyway (there is no `record`-construction syntax that looks
   like `[...]`), so this closes a checker/codegen split, not a usability
   regression: the correct way to build a value of a user's own `List[T]`
   record was always its own constructor syntax, never a bracket literal.

**Verification.** `lyric-compiler/lyric/typechecker_self_test.l` gains cases
for: a bracket literal typing directly as `List[T]` via explicit `return`,
a block's trailing value, an expression-bodied function, and both `if` and
bare-expr `match` arms; a `slice[T]` VALUE still rejected at each of those
same return-position forms; a user-defined `record List[T]` (unimported
stdlib) no longer accepting a bracket literal as if it were `Std.Collections.
List`; and the pre-existing `.toList()`/binding/ctor-field/call-argument
literal-typing tests migrated to a real `Std.CollectionsHost` import
(`stdCollectionsHostPackages`, reused from the #7665 tests) so the
id-based gate has a genuine stdlib `List` to resolve against. All
`typechecker_self_test.l` cases pass, plus a dual-target runtime self-test
(`return_list_literal_self_test.l`) that returns list literals from
`List[T]`-typed functions on `--target dotnet` and `--target jvm` and
asserts runtime values (count, elements, and that `.add` still works on the
result — proving a genuine `List<T>`/`ArrayList` was built, not a
slice/array), plus `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh`,
`scripts/ci/native-backend-self-tests.sh`, `scripts/ci/jvm-ecosystem-
suites.sh`, and every `lyric-*/lyric.toml` and `examples/*/lyric.toml` test
suite on `--target dotnet`.

**Codegen note.** No MSIL or JVM codegen change was needed. MSIL's `SReturn`
and function-tail lowering already push the declared return type onto
`collExpect` before lowering the returned/tail expression (`pushCollExpect
(fctx, fctx.declaredRetTy)` — pre-existing, #2289/#4965), and this scope
already covers nested `if`/`match` tail branches lowered within it, so the
checker now simply agreeing that the expression IS `List[T]` is sufficient
for the existing `EList` codegen arm to build a genuine `List<T>` there.
JVM's `EList` codegen builds a `java/util/ArrayList` unconditionally,
regardless of context — since `List[T]`'s own JVM runtime representation
already IS `ArrayList`, a returned list literal was always going to produce
the correct value; only the type CHECKER previously disagreed and rejected
the program before codegen ever ran.

**Scope note.** This entry does not extend literal-typing to an `if`/`match`
arm used in a position OTHER than the four already covered (return,
binding, ctor field, call argument) — e.g. an `if`/`match` literal arm
assigned to an unannotated binding, or nested inside an arbitrary
subexpression, still infers `slice[T]` per D-progress-1025 unchanged. It
also does not extend to a lambda body's own return value (out of scope;
`tailExpected` is `TyError` there).
