# Lazy copy-on-write `buffer[T]` on dotnet and the JVM (#8389, D226)

A managed `buffer[T]` is now a handle over its storage: a copy marks the storage
shared and costs O(1), and the first write after it makes the storage private.
Passing a large buffer to an `in` parameter, returning it, or handing it to
`spawn` no longer copies it. Observable value semantics are unchanged; native
was already lazy (reference count) and is unchanged except for the fix below.

- **Lowering** (`Lyric.ContractElaborator`, `array_ops.l`): reads, `.length` and
  `for` go through the handle's storage; a copy site becomes `shareHandle`; a
  write (`=`, `op=`, and a write to an element array) becomes an ensure-unique
  step followed by the write, with a value that can run code bound first.
  `Lyric.TypeAliasResolve` spells `buffer[T]` as `List[List[T]]`. D226 has the
  design and why the handle is a list, not a record.
- **`Std.Buffer`** builds its results as `val made: buffer[T] = list.__lyric_buffer_from_list()`;
  the annotation is where the handle lowering reads the element type.
- **Fixes found on the way.** A record's `.copy(...)` shared a buffer field with
  the original (it copied array fields only); the copy of an array whose element
  is a buffer of primitives emitted an intrinsic the JVM could not resolve; and
  native's `b[i] = f(b)` made the buffer unique before evaluating `f(b)`, so a
  copy `f` kept saw the write (the index and value are now evaluated first).
- **Tests.** `buffer_self_test.l` (sharing, write-after-share in both
  directions, compound and `inout` writes, a value that copies the buffer,
  record fields and `.copy`, generics, and allocation checks through
  `allocatedBytes()` that fail on the eager copy), `buffer_spawn_self_test.l`
  (shared snapshots across tasks, a task writing its own copy, a spawn that
  allocates nothing proportional to the buffer), and the new
  `buffer_nested_self_test.l` (dotnet and JVM; native cannot yet write a buffer
  nested with an array, #8521). `benchmarks/bench_buffer.l` gains
  `benchBufferPassIn`.
- W0030 is unchanged: `var b = a` followed by a write loop still copies at the
  first write on every target.
