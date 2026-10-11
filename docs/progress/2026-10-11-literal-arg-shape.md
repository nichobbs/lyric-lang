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

- `adoptListLiteralArgs` (type checker): after a call's arguments are
  checked, a bracket literal argument whose parameter is a stdlib `List` is
  checked against that `List` and takes its type. A generic callee's
  parameter is instantiated from the other arguments only (literal arguments
  masked out of the inference); a type parameter they leave open takes the
  literal's own element type. A literal whose elements do not fit keeps its
  own type, for the call's existing check to report. The same applies to a
  record's or union case's `List` field (`adoptedListLiteralType`), and to a
  generic record's `List[T]` field (`genericCtorListFieldTypes`). The
  recorded type arguments, the hoisted operand's type and the argument-order
  site then all see the `List`.
- `recordSliceShapedElement` (type checker): a bracket literal that is an
  element of a literal checked against a `List`, `slice` or `array` whose
  element type is a slice is recorded in `SymbolTable.listLiteralTypeSites`
  at that slice type, with the new `ListLiteralTypeSite.shapeRequired` set.
  A slice of slices now checks its elements against the inner slice type.
  `Lyric.Pipeline` passes the JVM only the `shapeRequired` sites
  (`shapeRequiredListLiteralSites`), where it passed none before, so
  `Lyric.Mono` binds such an element to a local of its slice type and every
  backend builds it as one.
- `recordCtorArgOperandTypes`: a bracket literal argument of a generic
  record's construction is recorded at the shape its field gives it, so
  dotnet, whose generic records are reified, builds `GBox(items = [1, 2])`'s
  literal as a `List<int>` rather than an `int[]`.
- `argTEForParamMono` (`Lyric.Mono`): a bracket literal passed where the
  parameter is a `List` counts as that `List` when inferring the callee's
  type arguments, so `size([a, b])` inside a generic function (where the
  checker's recorded type arguments do not apply to the specialised body)
  specialises.

Tests: `literal_arg_shape_self_test.l` (5 cases, dotnet, JVM, native): the
#8192 repro, iteration and `slice[String]` elements; a `List` of slices bound,
in a record and a union case field, as a trailing value and returned; a
slice and an array of slices and widened `slice[Long]` elements; the #8193
repro at `Int` and `String`, from inside a generic function, and a generic
record's `List[T]` field with and without an annotation; a literal beside or
before a `List` at a bare `T`, widening to a `List[Long]`, and two literals
at a bare `T` staying slices. Wired into the compiler, JVM-generics and
native batches and the `ilverify` list. `hoisted_literal_shape_self_test.l`
gains the #8191 repro and its mirror, `List[T]` and `List[slice[Int]]`
literals before a `?` and before an `await` (15 cases).
`typechecker_self_test.l` checks the recorded type argument for
`size([1, 2, 3])`, the hoisted literal's `List[Int]` type, the
`shapeRequired` sites for element literals of an argument and of a return,
and that the generic record construction is clean.
