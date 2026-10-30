# MSIL: nested-slice and slice-join ilverify errors (#7783)

Two more `object`-where-`T[]` families in the dotnet self-test corpus are fixed
and gated by `scripts/ilverify-selfhosted.sh`.

- A `for` loop over, or an index read of, a `slice[slice[T]]` produced the inner
  slice as the `object` the `IList` path returns. Both now convert with
  `emitObjectToSliceArrayMsil` (through `narrowBoxedParamMsil`), which copies a
  `List`-backed inner slice into a real `T[]`.
- A `match`/`if` whose fall-through arms are a genuine `T[]` slice beside a
  `List`-backed arm (`case None -> []`) bound the join to a `T[]` local while the
  stack held `object`. `unboxObjectArmsMsil` now converts the non-array arms
  (`joinedSliceArmsMsil`).

Files: `lyric-compiler/msil/codegen.l`, `scripts/ilverify-selfhosted.sh`.
Tests: `nested_slice_for_jvm_self_test.l` (new indexed-read case, both targets) and
`slice_string_self_test.l`, now both in the ilverify gate.

Not fixed: `slice_fastpath_listbacked_dotnet_self_test.l` declares an extern that
returns a `List` as `slice[String]` on purpose, so its ilverify error is the
test's own type lie. #8349 and #7517 (in-bundle generics reaching typed consumers
as `object`) stay open: a sound narrowing must handle erased `Box<object>`
constructions (docs/43, Q-GEN-002).
