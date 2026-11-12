# 2026-11-12 - TIR: owner arguments for a method call whose signature lists no generics (D581)

Fixes the eight I0003 `call-type-args` reports the post-#9018 census found in the self-tests. A method call on `Cell[T]`
now carries the receiver's type arguments, and the callee's symbol entry counts the owner's parameters. Two tests added
to `tir_build_self_test.l` (a generic function calling a method of a generic record; a method calling a sibling through
`self`); `tir_build` 150/150.
