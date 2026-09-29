# A `for` over a generator types its variable with the generator's element type (#7750)

An `async func g(): E` generator types its call as its element type `E`. The
type checker's `for` treated that type as the thing being iterated:

```
record Pt { x: Int, y: Int }
async func pts(): Pt { yield Pt(x = 1, y = 2) }
func sumX(): Int {
  var s = 0
  for p in pts() { s = s + p.x }   // jvm: J007 on `p.x`
  s
}
```

- A record or union element is not a recognized iterable, so the loop
  variable got the lenient `TyError`. `--target jvm` reads each element back
  through `java.util.Iterator.next()` as an erased `Object`, and nothing
  narrowed it, so `p.x` failed to compile with J007 ("member cannot be
  resolved on an erased (statically Object) receiver"). Binding
  `val pp: Pt = p` first worked.
- A `List[Int]` element was typed as the list's own element, `Int`.
- An `Option[Int]` element was rejected with T0126 ("cannot iterate over
  'Option[Int]'").

The fix, in the checker and both backends:

- The type checker takes a generator call's type as the loop's element type,
  whatever it is (`typechecker_stmts.l`'s `SFor`). This replaces the two
  special cases a tuple element and a `String` element had.
- The loop variable of a `for` over a generator is recorded in
  `SymbolTable.tuplePatternBindingSites`, as a tuple-pattern element is
  (#7741). `Lyric.Mono.desugarCheckedFile` then binds it through a local
  annotated with the element type, which is the form the JVM already narrows.
- JVM: a generator call's recorded generic arguments were its element type's
  own (`[Int]` for `Option[Int]`), so the `for` lowering's
  `indexedElemTypeOverride` unboxed each `Option` element as an `Integer`
  (`ClassCastException`). The call is the generated `Iterable` of the element
  type, so its arguments are now `[E]`, the shape a `List[E]` result has
  (`generatorIterableGenericArgs`). This also types the loop variable at the
  codegen level.
- JVM: a mono-specialised generic generator (`async func each[T](xs: in
  List[T]): T`) was registered in `collectMonoSpecializedSigs` with its
  element type as the factory's return type, so each call site linked against
  a method that does not exist (`NoSuchMethodError`). It now gets the same
  generator treatment as an unspecialised generator: an `Object` return and
  no element-derived return metadata.
- dotnet: `yield None` in an `Option[Int]` generator built an
  `Option_None<object>`, which the typed loop variable could not be cast from
  (`InvalidCastException`). A `yield` operand is now lowered against the
  generator's element type the way a `return` operand is lowered against the
  declared return (`LazyGenCtx.elemTy`, with type-argument hints and the
  collection-literal expectation). The fallback to the method's declared
  return is turned off there, because that return belongs to `MoveNext`.

Verified by the new dual-target `generator_element_type_self_test.l` (11
cases), wired into `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`. The cases iterate generators
that yield a record, a nested record, a union with a nullary case, a
`List[Int]` and an `Option[Int]`, plus a generic generator specialised to a
record and to an `Option`. Each case reads members of the loop variable or
matches on it directly. Before the fix, both targets rejected the file with
T0126. Without the `Option` cases, dotnet passed and the JVM failed to compile
with J007.
