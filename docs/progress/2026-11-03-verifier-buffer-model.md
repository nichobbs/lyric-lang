# Verifier: `buffer[T]` as a length-and-elements value (#8394)

`lyric prove` modelled `buffer[T]` as an opaque datatype `buffer[T]`: an
element read or write, or `.length`, failed closed (`V0033`/`V0026`), so no
code over buffers could be proved.

A buffer is now the preamble datatype `(Lyric!Seq T)` (the representation
arrays and slices already share), under a sort of its own, `SBuffer`:

- `buffer[T]` is the built-in buffer only where no type named `buffer` is in
  scope, the checker's rule (`bufferNameIsBuiltin`). `goalsForFile` marks the
  file in the distinct-type map when it can name no other `buffer` (none
  declared in it or a sibling file, none imported by name, no whole-package
  import outside `Std.*`); without the mark a `buffer[T]` stays the
  uninterpreted datatype it was, so an unknown case fails safe.
- `b[i]` is `(select (Seq!elems b) i)`, with the bounds obligation against
  the runtime length and the element type's width. `b[i] = v` and
  `b[i] op= v` on a buffer variable store, through the array write
  (`wpAssignElement`), with the same obligations.
- A copy is a value of its own (docs/01 §2.7), so a write needs no frame
  condition. This was checked at run time first on dotnet and the JVM: a
  write to a `var` copy, to an `in` parameter's local copy, and to the
  original after a `spawn` took it, is never seen through the other binding.
- The length changes only when the variable takes another buffer (`grow`,
  `truncate`, an assignment), so a loop or an `out`/`inout` argument that may
  change the variable keeps no length; an array keeps its length there
  (`isArraySort`, now in `theory.l` beside `isElementSequenceSort` and the new
  `isOwnedSequenceSort`).
- `==` on buffers fails closed: the language defines no buffer equality.

docs/01 §2.7's buffer bullet now says what a closure capture copies: a `val`
binding, while a closure over a `var` buffer shares the binding (§5.4), as for
any `var`. docs/15 §5.2 records that SMT `=` on `Lyric!Seq` also compares
positions past the length, which costs completeness but not soundness.
`typechecker_self_test.l` covers T0157 on a slice element of an array
(`a[0][1] = 5`).

`for x in b` over an array or buffer, and element writes through a field or a
nested element, still fail closed (`V0026`) and remain on #8394.

Tests: `verifier_self_test.l`, three buffer tests (reads, writes and copies;
length across a loop and an `inout` argument; a user type named `buffer`).
