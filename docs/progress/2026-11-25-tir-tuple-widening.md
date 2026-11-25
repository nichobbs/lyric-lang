# TIR builder: tuple literal elements widen to the literal's settled type

docs/70 phase 3c (#8613). The native census (4a) found nine functions in
`generic_ctor_widening_self_test.l` falling back with "field 0 has type i32 where the layout has i64".
Generic union and record constructions already reach TIR with `CvWiden` on the argument; tuple
literals did not: `(i, 1)` checked at `(Long, Int)` was typed `(Long, Int)` with an `Int` first element.

`buildExprBody` now passes the elements of an `ETuple` through `widenTupleElems`, which converts each
element whose type differs from the settled element type with `convertValue` (an element that does not
convert stays as built). Covered by `tir_build_self_test.l`
("a tuple literal checked at a wider tuple type widens its elements").
