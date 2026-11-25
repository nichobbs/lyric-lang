# TIR builder: out/inout place operands run in source order among named arguments

docs/70 phase 3c (#8613, #9383). The native via-TIR census found that
`inout_array_element_self_test.l` test 5 fails through TIR: in
`addBoth(b = note("b", 4), x = arr[at("i", 2)], a = note("a", 5))` the trace was b,a,i where D171
wants b,i,a. When names reorder the arguments, D575 binds each plain `in` argument to a temporary in
source order, but an `out`/`inout` argument's place kept its computed index (and a computed receiver)
inside the place, so it ran when the call was lowered, after the temporaries.

`buildCallArgs` now passes the place of a reordered `out`/`inout` argument through
`placeInSourceOrder`: an index or receiver that computes something (anything but a local, global,
literal, or a field or element of one) is bound to a temporary at the argument's source position,
receiver before index, and the place is rebuilt from the temporaries. A place-like operand stays
in the place, so a value-typed array or record the call updates is not copied. Covered by
`tir_build_self_test.l` (the temporaries are bound as b, i, a).
