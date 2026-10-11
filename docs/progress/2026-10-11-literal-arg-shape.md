# Bracket literals for `List` parameters, generic `List[T]` and `List[slice[T]]` (#8191, #8192, #8193)

Three reports about a bracket literal passed where a `List` is expected, all
reproduced on main after #8288:

- #8191: `pick(base, [1, 2], ok(5)?)`, with `pick[T](a: T, b: T, v: Int)` and
  `base: List[Int]`, failed JVM verification (`Object[]` where an `ArrayList`
  was expected). dotnet and native printed the right result only because
  `pick` never read `b`: a `second[T]` that returns `b` threw
  `InvalidCastException` (`Int32[]` to `List<Int32>`) on dotnet too.
- #8192: `count([[1], [5, 6]])`, with `count(xs: List[slice[Int]])`, threw
  `ClassCastException` (`ArrayList` to `Object[]`) on the JVM. The same held
  for a `List[slice[Int]]` binding, record and union case field and return,
  and for `slice[slice[Int]]` and `array[2, slice[Int]]` bindings.
- #8193: `size([1, 2, 3])`, with `size[T](xs: List[T])`, was accepted by the
  type checker and rejected by `Lyric.Mono` with `M0002` on every target.
  `GBox(items = [1, 2, 3])` for `record GBox[T] { items: List[T] }` was
  `T0110`.

**Root cause.** A call argument that is a bracket literal kept its own type,
`slice[E]`, in the call's argument types; the checker accepted it at a `List`
parameter only through `literalArgSatisfiesParam`. So everything computed
from the argument types saw a slice: a generic callee's type arguments (a
slice beside a `List` at a bare `T` is a conflict, so `T` was unbound and the
hoist recorded no shape for the literal, #8191; a slice binds nothing in a
`List[T]`, so no type argument was recorded for `Lyric.Mono`, which in turn
inferred `slice[Int]` from the literal itself, #8193), and the literal's
elements were never checked against the `List`'s element type, so nothing
recorded that `[5, 6]` is a slice. The JVM builds every bracket literal as an
`ArrayList` and converts it to an array only where its position names a
slice (a slice binding, a slice parameter); an element of another literal has
no such position, so it stayed an `ArrayList` (#8192). dotnet and native
build an element from the outer literal's type, which they see.

**Fix.**

- `adoptLiteralArgsOver` (type checker), reached through
  `adoptListLiteralArgs` for function and method calls and
  `adoptCtorLiteralArgs` for record and union case constructions: after the
  arguments are checked, each bracket literal argument whose parameter or
  field is a stdlib `List` (or a slice of slices) is checked against it and
  takes its type. The literals are adopted one at a time in parameter order;
  a generic parameter or field is instantiated from the non-literal
  arguments and the literals adopted before it, and a type parameter left
  open takes the literal's own element type. A literal is checked against
  the target only once `literalFitsType`, which records nothing, finds its
  elements fit, so a failed attempt leaves no side-table records. A literal
  that does not fit a generic parameter is **T0043** (**T0104** for a field),
  naming the instantiated type: `k([1], ["s"])`, `f(["a"], 1)` and
  `pick(base, [1, 2])` with `base: List[String]` compiled before and crashed
  at run time. An adopted `List` literal is recorded in
  `hoistOperandTypeSites`, so `Lyric.Mono` binds it to a local of that type
  and every backend builds it as the `List` even where it does not see the
  parameter (a method's, `p.addAll([1, 2])` threw on dotnet; a generic
  record's field). `recordCtorArgOperandTypes` does the same for a
  construction checked against an expected type.
- `reportGenericBindingConflicts` (type checker): two arguments binding one
  type parameter of a generic function to types neither of which satisfies
  or widens to the other are **T0043**. `k(a, c)` with `a: List[Int]` and
  `c: List[String]` compiled and crashed at run time; nothing compared the
  bindings.
- `recordSliceShapedElement` (type checker): a bracket literal that is an
  element of a literal checked against a `List`, `slice` or `array` whose
  element type is a slice is recorded in `SymbolTable.listLiteralTypeSites`
  at that slice type, with the new `ListLiteralTypeSite.shapeRequired` set;
  a slice of slices now checks its elements against the inner slice type.
  `Lyric.Pipeline` passes the JVM the `shapeRequired` sites
  (`shapeRequiredListLiteralSites`), where it passed none before, so
  `Lyric.Mono` binds such an element to a local of its slice type.
- `argTEForParamMono` (`Lyric.Mono`): a bracket literal passed where the
  parameter is a `List` counts as that `List` when inferring a callee's type
  arguments, in a call, a method call, overload resolution and a generic
  union case construction passed to a generic function
  (`bagLen(Full(items = [1, 2, 3, 4]))`), so `size([a, b])` inside a generic
  function, where the checker's recorded type arguments do not apply,
  specialises.

Tests: `literal_arg_shape_self_test.l` (6 cases, dotnet, JVM, native): the
#8192 repro, iteration and `slice[String]` elements; a `List` of slices bound,
in a record and a union case field, as a trailing value and returned; a
slice and an array of slices, widened `slice[Long]` elements, and a slice of
slices as a record field and an argument; a dot-named method, a method in
the record and a generic method taking a literal; the #8193 repro at `Int`
and `String`, from inside a generic function, a generic record's `List[T]`
field with and without an annotation, a generic union case's field, and a
`List[Option[T]]` literal inside a generic function; a literal beside or
before a `List` at a bare `T`, widening to a `List[Long]`, and two literals
at a bare `T` staying slices. Wired into the compiler, JVM-generics and
native batches and the `ilverify` list. `hoisted_literal_shape_self_test.l`
gains the #8191 repro and its mirror, `List[T]` and `List[slice[Int]]`
literals before a `?` and before an `await` (15 cases).
`typechecker_self_test.l` checks the recorded type argument for
`size([1, 2, 3])`, the hoisted literal's `List[Int]` type, the
`shapeRequired` sites for element literals of an argument and of a return,
and that the generic record construction is clean; a second case checks that
mismatched literals (`k([1], ["s"])`, `f(["a"], 1)`, `pick(base, [1, 2])`)
are T0043, a generic record's mismatched field literal T0104, two values
binding `T` to `Int` and `String` T0043, and that a widening binding and
literals at an unbound bare `T` stay clean.
