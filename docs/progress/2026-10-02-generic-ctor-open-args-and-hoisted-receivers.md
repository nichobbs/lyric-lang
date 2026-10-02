# Generic constructors bind past an open argument; hoisted receivers take the method's type (#7844)

Two gaps #7823 left, both in `Lyric.TypeChecker`.

## Generic constructor inference

`Holder(value = None, fallback = 5)` for
`record Holder[T] { value: Option[T]; fallback: T }` failed with T0110. The
`None` bound `T` to a hole (`TyError`), and `inferOneGenericArg` kept the
first binding, so `fallback` could not fill it. #7823 had worked around this
for the await hoist only (`inferGenericArgsJoined`). The fill now happens in
`inferOneGenericArg` itself: a hole is replaced by a later binding, and a
partly open binding (`Option[<hole>]`) is joined with it. Every generic call
gets it, functions and record and union-case constructors alike, and the
#7823 helper is gone. `pick(None, 5)` with `pick[T](a: Option[T], b: T): T`
now types as `Int` rather than an error-typed wildcard.

A union case's arguments were also paired with its fields in call order, so
`Pair(second = 8, first = None)` bound `T` from the wrong field. They are now
put in field order first, as a record's are.

Fixing inference exposed a --target dotnet miscompile behind it.
`val m = Middle(first = 1, maybe = None, last = 2)`, which already inferred,
failed at run time with "match not exhaustive". The MSIL lowering builds a
generic constructor's arguments before it picks the instantiation, so with no
type around the construction the `None` was an `Option<object>` stored in an
`Option<int>` field. The checker now records an argument whose own type is
open at its field's type, in the same `hoistOperandTypeSites` map #7823 uses.
Mono binds it to a local of that type on every target. The record is made
only when the construction's type is closed and the argument's is not, so
other constructor calls are unchanged.

## Hoisted receivers

A method-call receiver evaluated before an `await` or a `?` in the arguments
is hoisted to a local (#7850). It was recorded at its own type only, so a
receiver whose own type is open got an untyped local. The checker now takes
the receiver's type from the method it resolved:

- a dot-named function's receiver parameter;
- a method of the receiver's own type, with the receiver's type arguments as
  fresh variables;
- a stdlib `List`/`Map`/`Set` member's parameters.

The type parameters are bound from the receiver and the other arguments, and
then from the type expected of the call's result. The result type comes from
`inferExprExpected`, through `SymbolTable.methodCallResultExpected`, while the
call is checked. When none of these fixes the type, the call is now **T0154**,
which asks for the receiver to be bound to an annotated local. Before, it
built an open instantiation.

The issue's own example, `None.m(await g())`, also hit an older gap. A
method-style call to a free or dot-named function on a union receiver
(`o.unwrapOr(d)` on an `Option`) type-checks, but neither backend dispatches
it (dotnet panics "unsupported method", the JVM fails verification), with or
without an `await`. That is filed separately. The tests therefore use a
record-method receiver (`emptyCell().orDefault(await five())`), which runs.

## Verification

- `generic_ctor_open_arg_self_test.l` (new, 8 tests: `None` first, middle and
  last; named in and out of order and positional; a union case; a generic
  body; a generic function). It passes 8/8 on `--target dotnet`, `jvm` and
  `native`. Before the change the `Holder` cases did not compile (T0110), and
  on dotnet the middle and last cases failed at run time.
- `await_hoist_typed_self_test.l` gains an open receiver typed from the
  argument and one typed from the expected result. It passes 14/14 on dotnet
  and the JVM.
- `typechecker_self_test.l` gains two tests (802/802). The first covers
  constructor and function inference past an open argument. The second covers
  T0154: present when nothing fixes the type, absent when an argument, the
  expected result or a `List.add` element fixes it, and absent with no await.
  Both tests failed against the previous checker.
- The new test is added to `compiler-self-tests-batch.sh`,
  `jvm-generics-self-tests-batch.sh`, the native cross-target list in
  `native-backend-self-tests.sh`, and ilverify phase 4.

Documented in docs/01 §2.11 (generic constructors and functions) and §7.2
(hoisted operands), docs/09 §14.5, and book appendix B (T0110, T0154).
