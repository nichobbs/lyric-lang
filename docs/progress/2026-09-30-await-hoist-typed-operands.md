# Hoisted await operands keep their position's type (#7823)

In an `async func`, `Lyric.AwaitHoist` binds every operand evaluated before
an `await` in the same expression to a fresh `val`, so the await never
suspends with operands on the MSIL evaluation stack. The `val` had no
annotation. An operand that carries no evidence of its own type arguments
was then typed from the value alone, and on `--target dotnet`, where
generics are reified, it was built at the wrong instantiation:

```lyric
func addOpt(a: in Option[Int], b: in Int): Int { ... match a ... }

async func f(): Int {
  addOpt(None, await five())   // dotnet: "match not exhaustive"
}
```

The hoist produced `val __lyric_hoist_0 = None`, which MSIL built as an
`Option_None<object>`. That is not an `Option<int>`, so the callee's match
recognised neither case. `Ok(2)` and `Err("ab")` became `Result<int,
object>` and `Result<object, string>`, `newList()` a `List<object>`
(`InvalidCastException`), and `[None, Some(await five())]` failed the same
way. `Lyric.Propagate`'s `?` hoist shares the engine and had the same gap.
The JVM erases generics and was never affected.

## Fix

The hoist runs last in the middle end, after the type checker, mono and the
weaver, so it cannot ask the checker for a type. The type now travels with
the operand:

- **The type checker records each hoisted operand's type**
  (`SymbolTable.hoistOperandTypeSites`, keyed by the operand's span). For
  every operand evaluated before one containing an `await` or a `?` (the
  test is `Lyric.HoistEngine.exprHasHoistHazard`, the hoist's own), it
  records the operand's own type with each hole filled from the type its
  position expects: a function, method, record-constructor or union-case
  argument (its parameter or field type, generic parameters bound from the
  call), a list element (the literal's joined element type, or the expected
  `List` element), a tuple element holding the hazard, and the left operand
  of an eager binary operator (the right operand's type). Only closed
  generic instantiations are recorded; the type may name the enclosing
  function's type parameters. Literals and locals are skipped.
- **Generic arguments are inferred past a hole.** The expected argument
  types of a generic call bind each type parameter with
  `inferGenericArgsJoined`, so in `f(None, 5)` with `f[T](a: Option[T], b:
  T)` the `None`'s hole does not hide the `Int` the second argument fixes.
- **`Lyric.Mono.desugarCheckedFile` binds each recorded operand** to
  `{ val __lyric_ho_<n>: T = <operand>; __lyric_ho_<n> }`, the typed-local
  shape #7716, #7728 and #7818 use. It runs before specialisation, so a
  generic body's `Option[T]` is substituted like any other annotation, and
  mono's `inferExprTE` sees through the block when it infers a generic
  call's type arguments. It runs on every target.
- **`Lyric.HoistEngine.hzBind` keeps the annotation.** An operand ending in
  a typed local is bound as `val <fresh>: T = init` (or `= <block>` when
  hoisting added statements inside it), so the fresh local is typed at its
  position's type on MSIL, the JVM and native alike.

`ctorArgExpectedTypes`/`argTypesAgainstFields` factor the per-argument field
types out of `noteCtorArgFlows` (#7788), which now uses them too.

## Tests

`lyric-compiler/lyric/await_hoist_typed_self_test.l` is a dual-target
`@test_module` with 11 cases, each really suspending (`Std.Task.delay`):
`None`, `Ok`, `Err`, `newList()` and `newMap()` arguments before an awaited
one; a generic callee; generic async bodies (`Option[T]` at `Int` and
`String`); list literals holding `None` (passed, iterated, `Ok`/`Err`,
`List`-typed); record, generic-record and union-case constructor arguments;
`None == await ...` and `Ok(5) == await ...`; a method argument and a method
receiver; a tuple element; and an operand before an awaited, propagated
(`?`) argument.

- dotnet before: failed to compile (M0002: mono could not infer `T` for
  `countNone(None, await echo(x))` in the generic body). With that call
  removed, 9 of 11 cases failed at run time. After: 11/11.
- jvm: 11/11 before and after.

It is added to `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh` and phase 4 of
`scripts/ilverify-selfhosted.sh`. The rule is documented in docs/01 §7
(`await` in operand position) and docs/09 §14.5.

## Follow-up: standalone tuples and composites the hoist binds whole (#7850)

Review of #7849 found that a tuple literal was covered only as a call or
constructor argument. `val t: (Option[Int], Int) = (None, await five())`, a
function returning `(None, await five())`, and an assignment of one still
hoisted the `None` to an untyped local. The checker's `inferExprExpected`
now has an `ETuple` arm: each element is checked against its expected
element type, and the elements the hoist binds are recorded at it (nested
tuples included); `inferExprCore`'s `ETuple` arm records closed element
types too.

An audit of what else the hoist binds found three more gaps, now recorded:

- an `if`, `match` or block operand whose arms hold the `await`
  (`addOpt(if c { None } else { Some(await f()) }, 1)`), and a short-circuit
  operator, which the hoist binds as a whole at the operand's type;
- the value of a field or element assignment holding an `await`
  (`cell.o = if c { None } else { Some(await f()) }`), bound whole at the
  target's type;
- a method-call or index receiver evaluated before an awaiting argument or
  index, at its own type when that is closed.

Interpolation segments are stringified, so their instantiation is not
observable, and range bounds are integers.

Seven cases were added to `await_hoist_typed_self_test.l` (14 tests):
annotated `val` tuple, tuple as a function's value, `return`ed tuple,
assigned tuple, two nested tuples, `if`/`match` operands whose arm awaits,
and a field assignment whose value awaits.

- dotnet before: 11/14 (the three new tests failed with
  `InvalidCastException` / "match not exhaustive"); after: 14/14.
- jvm: 14/14 before and after.

Not covered, and independent of the hoist (both fail on dotnet without any
`await`): an unannotated `val t = (None, 5)` whose later use fixes the
element type, and `cell.o = if c { None } else { Some(5) }` in synchronous
code.
