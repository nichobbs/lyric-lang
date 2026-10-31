# Captured `var` passed `inout`: the three #8204 shapes pinned (#8204)

#8204 listed three argument shapes where a closure-captured `var` passed as
`out`/`inout` was copied in and out, so a closure write made during the call
was overwritten when the call returned. Re-running the issue's three repros
on current `main` on dotnet and the JVM, all three print the expected value
(`new`, `5`, `5`). They were fixed by earlier work and the issue's open
state came from stale triage comments:

- **dotnet type-parameter cell (shape 1):** #8284 made the closure class
  generic over the enclosing type's parameters, so the cell is a typed
  `!0[]` (`cellUsesTypedArrayMsil` accepts `MTypeVar`) and `ldelema !0`
  aliases it. D183's note that this shape "still copies" predates #8284.
- **dotnet `inout Self` (shape 2):** D183 / #8373 pass the cell's address
  reinterpreted with `Unsafe.As` (`MCallUnsafeAsByref`) instead of copying.
- **JVM primitive at generic `T` (shape 3):** D183 passes a `Lyric$Ref$L`
  with a boxing adapter over the caller's cell.

Also confirmed on both targets: the same variable passed to an erased
`inout Self` and to a typed `inout`, a generic function and a generic
record method at `Int`, `Long`, `Bool`, `String` and record instantiations.

## Tests

`closure_captured_var_byref_self_test.l` gains three cases (38 total, passing
on `--target dotnet` and `--target jvm`): a closure write during a call is
kept for a type-parameter-typed captured `var` in a generic record method
(`String`, `Int`, record instantiations, with and without the callee reading
the value after the closure runs), in a generic function, and at primitive
instantiations of `inout T`. The `inout Self` shape was already pinned by the
file's #8204 cases. Native closures capture a variable's value (#7891), so the
closure cases do not run there; `inout_aliasing_self_test.l` covers native.

## Also

`Lyric.Pipeline` did not build on `main`: #8651 added two `SourceFile`
constructions after #8650 made `files` a required field (T0105). Both now
pass `files`.
