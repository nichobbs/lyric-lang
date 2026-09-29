# A `var` in a generator body is captured by reference by its closures, on both targets (#7715)

A closure inside an async generator (`yield` in an `async func`) that
mutated a `var` declared in the generator body was miscompiled on both
backends:

```lyric
async func g(step: in Int): Int {
  var acc = 1
  val bump = { -> acc = acc + step }
  yield acc
  bump()
  yield acc
}
```

- `--target jvm` yielded `1, 1` instead of `1, 1 + step`. This was a silent
  wrong value. `lowerGeneratorBody` builds its `FuncCtx` through
  `makeFuncCtxForGenerator`, whose `hoistedVarNames` starts empty, and it
  never ran the by-reference capture pre-pass. The `var` therefore got a
  plain slot, and the closure captured a copy of it. This is the same gap
  that #7690 (methods) and #7694 (lambda and `spawn` bodies) closed
  elsewhere.
- `--target dotnet` failed to compile, with the `hoistedVarNames`-miss
  invariant panic (`captured mutable (`var`) local 'acc' was not hoisted to
  a heap cell`). The cause was the same missing pre-pass, this time in
  `synthesizeGeneratorMsil`'s `MoveNext` context.

Fix: `lowerGeneratorBody` now runs `runClosureCapturePrePassJvm`, and
`synthesizeGeneratorMsil` now runs `runClosureCapturePrePassMsil`.

- On the JVM the generator body runs to completion on its own producer
  thread, so the cell's slot stays live across yields without any extra
  work.
- On MSIL the cell is an ordinary `MoveNext` local. The generator's yield
  save/restore therefore carries the cell reference, not its value, across
  resumptions.
- The MSIL Pass-1 generator field-count predictor had to change too.
  `countGeneratorFieldsMsil` and `countGenLocals*` now take `cctx`,
  `pkgName` and the captured-name set, and count a captured `var` as the two
  slots `finishHoistedCellMsil` allocates: its `__cell_init_<n>` value slot
  and the cell. Before this, `synthesizeGeneratorMsil`'s field-count
  cross-check panicked.

Covered by the new dual-target
`lyric-compiler/lyric/generator_closure_var_capture_self_test.l`, which has
seven cases:

- a mutation before the first yield
- mutations between yields
- a closure first called after a yield
- a `var` declared inside a loop body, which gets a fresh cell per iteration
- a closure that returns the value it wrote
- accumulation over a list
- an uninitialised captured `var`, followed by a record declared after every
  generator (this checks the FieldDef token prediction)

The file is wired into `compiler-self-tests-batch.sh` (dotnet) and
`jvm-generics-self-tests-batch.sh` (jvm). Before the fix, every case failed
on the JVM with the pre-mutation value, and the dotnet build panicked.

Separate bug, not fixed here: a `for` loop inside a generator body fails on
both targets, closure or not. On MSIL the Pass-1 predictor does not count
the `for`-loop iterator temps, so the build panics. On the JVM the build
throws `VerifyError: Expecting to find integer on stack`. Tracked in #7718.
