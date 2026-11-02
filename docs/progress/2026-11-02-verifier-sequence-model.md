# Verifier: arrays and slices as length-and-elements values (#8394)

`lyric prove` modelled an array or slice as a bare SMT `(Array Int T)` with
its length an uninterpreted function `$len` of that array (#8157). That was
unsound: over an element sort with one value (`Unit`, a one-case enum) every
SMT array is the same array, so two sequences of different lengths were
contradictory and any goal over them discharged (`func f(a: in array[2,
Unit], b: in array[3, Unit]): Bool ensures: result { false }` proved). It was
also incomplete: an element read was a fresh value, so `a[0] == a[0]` did not
prove and a contract could not speak of elements, and an element write failed
closed (`V0026`).

An array or slice is now the preamble datatype `(Lyric!Seq T)`, a length
`Seq!len` and the elements `Seq!elems : (Array Int T)`:

- `xs.length` and the index bound read `Seq!len`; `String` keeps its length
  function.
- `xs[i]` on an array or slice is `(select (Seq!elems xs) i)`, with the bounds
  obligation as before; where the receiver is a variable or parameter the
  element lies in its type's range and width (`SortInfo.elemRange`,
  `elemIntBits`), and a distinct or range element type takes its underlying
  sort, as a variable of that type does.
- `a[i] = v` and `a[i] op= v` on an array variable rebind `a` to the
  `BOpSliceStore` of it: the bounds obligation, the element type's range and,
  for a compound operator, the divisor and overflow obligations a variable
  gets (`assignedValue`, now shared by both). An array is a value (docs/01
  §2.7), so a copy needs no frame condition. A loop that writes an array keeps
  its length through the havoc (`fixedLen`), which is now also kept when the
  file shadows `Result`/`Option`.
- A field's array (`r.a[i] = v`), a nested element (`a[i][j] = v`), an index
  that assigns or passes `out`/`inout`, and a value that changes the array
  still fail closed (`V0026`). `buffer[T]` is still an opaque datatype, and
  `for x in a` is still `V0026`; both remain on #8394.

docs/15 §3 (sort table, index reads, element writes) describes the model.
Tests: `verifier_self_test.l`, the five #8394 tests (length is part of the
value, element reads, element writes, a loop writing an array, writes that
fail closed) and the rendering of the three sequence builtins.
