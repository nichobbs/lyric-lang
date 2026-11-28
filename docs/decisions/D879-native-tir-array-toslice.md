# D879: the native TIR lowering takes `array.toSlice`

Status: accepted (docs/70 phase 4a, part 10; D520 slice 54).

## Decision

`a.toSlice()` on an array reaches TIR as the builtin `array.toSlice` (a copying conversion: the AST path's `Lyric.ContractElaborator.lowerArrays` rewrote it to a loop before the backend, the TIR builder does not). The native lowering copies: a heap array (held as a list) through the runtime's `lyric_list_copy`, an inline array by storing it to a stack slot and pushing each element in order onto a fresh slice (an aggregate element is boxed per push, so the pushes are unrolled; an array of more than 256 elements stays on the AST path with the census reason "toSlice of an array of N elements"). The slice is a new owned list, so later writes to the array do not show in it.

`slice_fastpath_self_test.l` builds from TIR through the census.
