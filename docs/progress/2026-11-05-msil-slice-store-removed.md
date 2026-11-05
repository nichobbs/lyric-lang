# MSIL: the slice element-store codegen is removed (#8729)

T0157 (docs/01 §2.7) rejects `xs[i] = v` and `xs[i] op= v` on a `slice[T]`, so
the MSIL lowering for them could no longer be reached from source. Removed from
`msil/codegen.l`: the plain-store arm for an `MArray` receiver (the `stelem`
fast path for a genuine `elem[]`, #7259, and its `IList.set_Item` fallback for a
`List`-backed slice), `emitSliceCompoundAssignMsil` (#7343), `emitListSetItem`'s
`MArray` arm (#5842) and the `IList.set_Item` MemberRef every module carried for
them. An `MArray` receiver at an element store is now an internal compiler error
naming T0157. `array[N, T]` and `buffer[T]` lower to `List<T>` on dotnet and are
unaffected; the JVM `JArray` store arms (used by `array[N, T]` of a primitive)
and the native `lowerIndexAssign` (shared with `List[T]`, D-N-015) are unchanged.

Before removal, IL of `slice_fastpath_self_test.l`,
`slice_fastpath_listbacked_dotnet_self_test.l`, `inout_slice_self_test.l`, the
self-hosted compiler bundle (`Lyric.Compiler.dll`) and the stdlib bundle held no
`IList::set_Item` call, which every slice element store emitted.
