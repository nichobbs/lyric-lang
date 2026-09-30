# List literals are built at their joined element type (#7818)

`[Some(1), None, Some(3)]` has element type `Option[Int]`, but no single
element says so: `None` fixes nothing. On `--target dotnet` this was a silent
miscompile, in synchronous code as well as async:

```lyric
var t = 0
for o in [Some(1), None, Some(3)] {
  match o { case Some(v) -> { t = t + v } case None -> () }
}
// dotnet: a large nonsense number; JVM: 4
```

Root causes:

- **The type checker never joined the element types.** The `EList` arm took
  the first element's type and only checked that the others were
  `typeEquiv` to it, and `typeEquiv` treats a hole as matching anything. So
  `[None, Some(5)]` typed as `slice[Option[<error>]]`, and nothing downstream
  knew the literal's real element type.
- **MSIL had no type to build an unannotated literal at.** With no
  collection type expected, codegen built a `List<object>`, lowered each
  element with no hint (`Some(1)` an `Option<int>`, `None` an
  `Option<object>`), and returned `object`. The loop variable was then an
  `object`, and the match read the `Some` payload through the wrong
  representation. That is where the garbage came from. It happened even
  when every element was a `Some`.
- **An expected element type did not reach the element either.** A literal
  in a `slice[Option[Int]]` position (an annotated binding, a parameter)
  whose element type has no array token took a fallback path that lowered
  the elements with no hint at all. So `None` was still `Option<object>`,
  and the reader's cast threw `InvalidCastException`. The `List[T]` path
  pushed only the nested-literal hint, so a bare `None` in
  `val xs: List[Option[Int]] = [None]` borrowed the binding's own type
  arguments and was built as an `Option<Option<int>>`.

Fixes:

- The checker now joins the element types (`joinOpenTypes`): a type
  argument one element leaves open is taken from another. The literal is
  typed at the join, so `[None, Some(5)]` is a `slice[Option[Int]]`.
- A literal checked with no collection type expected of it, whose element
  type is or contains a generic instantiation, is recorded in a new
  span-keyed channel, `SymbolTable.listLiteralTypeSites`
  (`Lyric.Parser.ListLiteralTypeSite`). Its type may name the enclosing
  function's own type parameters, which Mono substitutes when it specialises.
  A literal also checked where a `List` is expected (an annotated binding, a
  `List` parameter or constructor field) is marked `conflicting` and left
  alone, because codegen builds it as that `List`. `Lyric.Mono.
  desugarCheckedFile` rewrites a recorded literal to
  `{ val __lyric_ll_<n>: slice[T] = [...]; __lyric_ll_<n> }`. This is the
  same typed-local shape the #7716 and #7728 desugars use, so the annotated
  binding path builds and reads the value. Mono's `inferExprTE` sees through
  that block shape (`typedLocalBlockTE`), so a generic call taking the
  literal as an argument still infers its type arguments.
- The binding is gated by a new `MiddleEndOptions.bindListLiteralTypes`. It
  is on for MSIL and native, where generic instantiations are distinct
  runtime types. It is off for the JVM, which erases generics: its literal
  is an `ArrayList` of erased elements, and its element-type recovery reads
  the literal itself. The JVM was correct before this change and is
  unchanged.
- MSIL lowers every collection-literal element through `lowerCollElemMsil`,
  which pushes the element type both as the nested-literal hint and as the
  type arguments of a generic case construction. This covers the concrete
  `List`, typed-array, erased-`List<object>` and inferred-array paths.
- An indexed read of an erased slice whose element type is a closed stdlib
  generic (`Option<int>`) now casts the element, as the `for` loop over the
  same slice already did (`emitCollectionForMsil`). Previously `xs[2]` fed an
  `object` into an `Option<int>`-typed match slot, which ilverify rejected.

`lyric-compiler/lyric/list_literal_join_self_test.l` is a new dual-target
test with 11 cases:

- mixed `Some`/`None` literals, with `None` first and with `Some` only, each
  iterated;
- a literal bound, indexed and counted;
- a literal passed to a `slice` parameter, and one returned through a local;
- annotated `slice`/`List` literals holding `None`, a `List` parameter and a
  `List` record field;
- `Ok`/`Err` mixes;
- `Option[Option[Int]]` elements, and a literal of literals;
- tuple elements and a `String` payload;
- a generic callee, and a literal built in a generic body;
- an element that awaits.

Results:

- dotnet before: the file did not compile. The nested `[Some(None), ...]`
  literal typed as `Option[Option[<error>]]`, and codegen could not resolve
  the pattern binding (T0115). Without that case it ran 0/11 with 10
  ilverify errors.
- dotnet after: 11/11, 0 ilverify errors.
- JVM: 11/11 before and after.

The test is in `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh` and `scripts/ilverify-selfhosted.sh`
phase 4. The join rule is documented in docs/01 §4.3 and book §12.4, and the
construction rule in docs/09 §8.3.

Also in this change, from the #7819 review: `lowerMatchExprMsil` now checks
the scrutinee temporaries it keeps across a suspending guard against
`matchScrutineeTempSlotsMsil` (`checkMatchScrutAwaitFieldsMsil`), as every
`for` protocol already did through `checkForAwaitFieldsMsil`.

Out of scope, and filed separately:

- An `await` hoist binds the operands evaluated before an awaiting one to
  unannotated temporaries. So `[None, Some(await f())]` and
  `add(None, await f())` still build that `None` as `Option<object>` on
  dotnet.
- A lambda literal whose body is a bare `None` (#7516).
- `[None, None]`, where no element fixes the type (#7516 item 3).
- On native, a tuple literal element holding `None` (`[(None, 1)]`) is still
  `N0007`, annotated or not.
