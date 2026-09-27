# Native: `Std.Collections.Persistent` compiles and runs (#7413)

`Std.Collections.Persistent`'s suites ran on dotnet and JVM but never on
`--target native`. Four native codegen gaps stood in the way; each is fixed in
`Lyric.LlvmCodegen`:

- **Type arguments from the expected type.** A generic function whose type
  parameter appears only in its return type (`plistEmpty[T](): PersistentList[T]`)
  had nothing to infer from. `lowerExprExpecting` now hands the expected type to
  the call it lowers, through a one-shot slot `lowerCallEx` takes before any
  argument is lowered, so only that call's own instantiation can use it. A
  generic record constructor (`PListSplit(prefix = ..., rest = ...)`) now binds
  its type parameters from every field (including ones nested in a generic
  instantiation, `List[T]`, `Map[K, V]` or `slice[T]`), then from the expected
  type.
- **Refutable patterns inside a tuple pattern.** `case (Some(a), Some(b))` tested
  only bindings and wildcards; each element is now tested in place.
- **Prelude `println`.** A program that calls `println` without importing
  `Std.Console` (as the MSIL and JVM backends allow) lowers straight to the
  runtime line write.
- **Top-level functions as values.** Passing `intEq` where an `(Int, Int) -> Bool`
  is expected lowers as the closure `{ (a, b) -> intEq(a, b) }`.

`llvm_heap_self_test.l` gains four cases (the last three under
AddressSanitizer), and `scripts/ci/native-target-smoke-test.sh` now runs both
persistent suites on native.
