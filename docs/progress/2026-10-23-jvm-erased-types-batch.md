# JVM backend: erased element types, branching wire initialisers, `.toList()`/`.toNat()` (#8281, #8237, #8132, #8162, #8372, #8323, #7662, #7661, #7298, #8007, #8078)

A batch of `--target jvm` fixes.  Each had a correct dotnet and native result.

## Types the JVM erased to `Object`

The JVM recovers an element's or field's concrete type from the generic
arguments it records for a binding (`ctx.varGenericArgs`) and reads back
through `scrutineeGenericArgs`.  Four shapes recorded nothing, so a read was
`Object` and `+` on two of them failed with J008:

- A module-level `val xs: List[String]` (#8281).  The declaring file now
  stores the annotation's arguments on the `val:` registry entry
  (`moduleValGenericArgs`), and `scrutineeGenericArgs` reads them for a bare
  name that is neither a local nor a field.
- An element of a nested collection, `s[0][0]` for `array[2, array[2, String]]`
  or `List[List[Long]]` (#8237).  `scrutineeGenericArgs` has an `EIndex` arm that
  takes the element's own arguments from the base's.
- An unannotated binding of a generic record built from a typed collection,
  `val h = H(xs = ys, tag = 0)` (#8132).  `genericRecordCtorArgs` solves a field
  declared `xs: List[T]` from the argument's recorded arguments.
- A bare-`T` field read of an unannotated `Box(first = "x", second = "y")`
  (#8162).  `narrowGenericFieldRead` narrowed only primitive instantiations; it
  now `checkcast`s to a reference one.

`buildArgsByParamName` paired a positional argument by counting positional
arguments; it now uses `Lyric.Parser.pairCallArgs`, as the checker does.

## A match or `if` that joins a `slice[Byte]` (#7298)

`orElse(opt, [])` specialised for `slice[Byte]` joined a `byte[]` payload arm
with an `Object[]` default arm in one result local; the StackMapTable typed the
local `byte[]`, so the default path failed verification.  The arms now coerce
with `coerceArgToCtx`, which narrows `Object[]` to `byte[]`.

## Branching wire binding initialisers (#8372)

A `wire` binding initialiser that branched produced a `bootstrap()` method with
no StackMapTable frame at the branch target.  Every binding's initialiser is
now its own private static method (`bootstrap$init$<name>`) assembled like an
ordinary function body, and `bootstrap()` calls them in order.  That also stops
slots and labels colliding across bindings or with `bootstrap()`'s own
`@provided` parameter slots.

## `slice.toList()` and `.toNat()` (#8323, #7662, #7661)

`slice[T].toList()` copies the array (boxed first for a primitive element) into
a fresh `ArrayList`.  `.toNat()` on `Byte`, `Char`, `Int`, `Long`, `Float` and
`Double` follows `emitCheckedToNatMsil`: `Byte`/`Char` widen, the rest go
through the `__lyricToNat`/`__lyricToNatD` helpers, which throw
`ArithmeticException` with the shared message on a negative value or NaN.
`slice_to_list_self_test.l`, `slice_func_tolist_self_test.l` (renamed from
`..._dotnet_...`) and `int_to_nat_self_test.l` now run on the JVM.

## Arity-keyed method lookups (#8007, #8078)

`methodSigJvm` falls back to the first-registered overload of a name only when
it can take the written argument count.  The return-generics lookup
(`instanceMethodRetGenericArgs`) and `isLambdaSelfField` use it instead of the
name-only `cls#name` key.

## Checked and already correct (#7206, #7652, #7630, #8351, #7367, #7184)

Each was verified against current `main` and needed no change: a package-private
function never leaks through a bare function reference (#7206; pinned by a new
case in `jvm_cross_package_collision_self_test.l`), an imported `JsonElement`
parameter of another package's function resolves (#7652, fixed by #7357),
`?` bindings (#7630), the curried generic-union `+` (#8351), `format1`-`format4`
(#7367, fixed by #7840) and `JvmCaseField.genericArgs` resolution (#7184).

## Tests

`jvm_erased_types_self_test.l` (dual-target) covers the erased-type shapes, the
`?` bindings of #7630 and the `slice[Byte]` join; `curried_generic_union_jvm_self_test.l`
covers #8351; `wire_templates_self_test.l` gained a branching-initialiser case.
They run from `jvm-generics-self-tests-batch.sh` and `compiler-self-tests-batch.sh`.
