# native: the TIR lowering takes `array.toSlice` (D879)

docs/70 phase 4a part 10. `a.toSlice()` copies the array into a new slice from TIR (`lowerArrayToSlice` in `llvm_tir.l`): a heap array through `lyric_list_copy`, an inline array element by element. The census loses the `array.toSlice` fallback; arrays of more than 256 elements stay on the AST path. Covered by `slice_fastpath_self_test.l`.
