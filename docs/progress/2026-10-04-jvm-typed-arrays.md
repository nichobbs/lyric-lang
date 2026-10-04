# JVM: a numeric `array[N, T]` is a typed Java array (#8041)

On `--target jvm` an `array[N, T]` was always a `java.util.ArrayList`, so
every element of a numeric array was boxed (D167 item 7). An array whose
element is a numeric type, `Bool`, `Char` or a range subtype of one is now
the typed Java array (`int[]`, `long[]`, `float[]`, `double[]`, `byte[]`,
`boolean[]`, `char[]`), with unboxed elements. Every other array stays an
`ArrayList`, including an array of arrays (`array[2, array[3, Int]]` is an
`ArrayList` of `int[]`). Nothing a program can observe changes; dotnet and
native are unchanged.

## Middle end

- `MiddleEndOptions.primitiveArrays`, set by the JVM bridge, keeps a
  primitive-element `TArray` when `lowerArraysToLists` turns the other array
  types into `List` (a `primitiveArraysKey()` marker for
  `Lyric.TypeAliasResolve`).
- The array fill and copy intrinsics stay intrinsics for such an array, as
  they do on native. A nested copy of a list of primitive arrays copies each
  element with the intrinsic.
- A bracket literal of a primitive array becomes the new
  `__lyric_array_of[array[N, T]](e0, ...)` intrinsic. The checker now records
  each bracket literal typed as an array (`SymbolTable.arrayLiteralSites`),
  and the array pass reads them.
- A bracket literal given to a union case field of array type is now typed
  against the field, as one given to a record field already was. Before,
  `Tri(pts = [1.0, 2.0, 3.0])` on an `array[3, Float]` field built `Double`
  elements, which the JVM could not unbox to `Float`.

## JVM backend

- `typeExprToJvm` maps a primitive-element `TArray` to `JArray(elem)`.
  Indexed reads, plain and compound writes, `for`, `inout` and `newarray`
  use the existing typed-array opcodes.
- The fill intrinsic is `newarray` followed by `Arrays.fill`, which is skipped
  for a literal zero. The copy intrinsic is `Arrays.copyOf`. The literal
  intrinsic is `newarray` plus stores.
- An `Object`-typed receiver used to be cast to `ArrayList` before indexing,
  which a typed array fails. It is now indexed through the per-package
  `__lyricErasedIndexGet`/`__lyricErasedIndexSet` helpers, which dispatch on
  the runtime class: `ArrayList`, a slice's `Object[]`, or a typed array.
  Examples of such receivers: a slice element that is an array, or a generic
  parameter's value.
- An erased value reaching a typed-array slot gets a `checkcast` to the
  array descriptor. Examples: a `List` element, a generic field read at a
  primitive-array instantiation, a generic function's result.
- A generic record's `array[N, T]` field is erased to `ArrayList`. A typed
  array stored into one, or copied out of one, is converted by the
  `__lyricArrToList_<X>`/`__lyricListToArr_<X>` helpers. Both directions are
  copies, which the ownership rule already requires.
- Auto-FFI accepts a typed array for a JDK `Object` parameter at the lowest
  score (`ArrayList.add` of an `int[]`).

## Verification

- `fixed_array_self_test.l`: 30 pass on dotnet, the JVM and native.
- `llvm_fixed_array_self_test.l`: 13 pass.
- `fixed-array-e2e.sh`, `range-refinement-e2e.sh` and `overflow-profile-e2e.sh`
  pass on all three targets.
- `typechecker_self_test.l`: 841 pass.
- The JVM self-tests run in CI were rerun against this build.
- A parity program covering these cases prints the same output on dotnet and
  the JVM:
  - an array in an `Option`, a tuple and a union payload;
  - `Byte`, `Bool`, `Char` and `Long` arrays;
  - an `inout` array parameter;
  - a module-level array `val`;
  - an array captured by a lambda;
  - a generic function over an array;
  - `==` on records holding arrays.
- New gate `scripts/ci/jvm-typed-arrays-nobox.sh`, run from
  `jvm-generics-self-tests-batch.sh`. It builds a `Vec3`-style program,
  checks its output, and requires `add3`/`dot3`/`sum4` to take and return
  `float[]`/`int[]` with no wrapper `valueOf` and no `ArrayList`. It fails
  on the previous compiler.

## Found and filed

- #8147: indexing a slice bound out of a tuple pattern fails JVM verification.
  This also happens on `main`.
- #8003: noted that a record whose field is an array needs element-wise
  hashing when used as a `Map` key. Record keys miss a structurally equal key
  on dotnet and the JVM today.
