# `Std.Collections.Persistent`: a linked `PersistentList[T]` (#7280)

`PersistentList[T]` was a bare `slice[T]`, so every `plistCons` and `plistTail`
copied the whole list and building or walking one step by step was quadratic.
It is now a cons-list union with each node's length cached:

- cons, head, tail and length are O(1);
- insert, delete and lookup are O(index), sharing the untouched suffix.

`collections_persistent_tests.l` builds and walks a 200,000-element list on
dotnet and JVM. `PersistentMap` stays an association list until the language
has a hash or ordering constraint (D-progress-980), and the module is now part
of the `Lyric.Stdlib` bundle.

Compiler fixes it needed, all in D-progress-980:

- **MSIL, cross-assembly references:** field and ctor references now keep a
  field that nests the type's own parameter, such as `tail: PersistentList[T]`
  or `prefix: List[T]`, in its open form.
- **Monomorphizer:** a generic call passed to another generic, such as
  `plistCons(1, plistEmpty())`, now takes its type from the outer call.
- **Native:** a self-referential generic union or record no longer overflows
  the compiler's stack. There is a new ASan case in `llvm_heap_self_test.l`.

Native still cannot run the module's tests, tracked as #7413.
