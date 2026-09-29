# A `for` loop inside an async generator body works on both targets (#7718)

A `for` loop in an async generator (`yield` in an `async func`) failed on
both backends, with or without closures:

```lyric
async func g(items: in List[Int]): Int {
  for it in items { yield it }
}
```

## `--target dotnet`: Pass-1 field-count panic

The build panicked in `synthesizeGeneratorMsil`'s field-count check
(`predicted 5 FieldDef rows but real synthesis produced 10`). A generator
hoists every `MoveNext` local to a field. The Pass-1 predictor,
`countGeneratorFieldsMsil`, has to know how many there will be before any
body is lowered, because every later type's FieldDef tokens depend on it. It
did not count the loop protocol's hidden temporaries (counter, bound, list,
index, element, enumerator, ...) or the loop pattern's bindings. Its doc
comment listed this as a known gap.

The fix derives the count from the lowering, not a separate hand count:

- Each `for` protocol's temporary-slot count is declared once, in
  `forProtocolTempSlotsMsil`: range 2, indexed list 4, indexed array with the
  typed fast path 5, `IEnumerable` 3, async enumerable 6. Every protocol
  allocates its temporaries through `allocForTempSlotMsil` and ends with
  `checkForTempSlotsMsil`. That check fails the build as soon as the
  allocation and the declaration disagree. It runs on every `for` the
  compiler lowers, not only in generators, so any future drift is caught by
  the compiler's own build.
- `countGenLocalsStmt`'s `SFor` arm adds the protocol temporaries and
  `forPatternSlotsUpperBoundMsil(pat)` (one slot per name, plus one per tuple
  position) to the iterable's and body's locals. A range loop's protocol is
  known from the syntax. For a collection loop, the protocol follows the
  iterable's lowered type, which Pass 1 does not have, so the predictor takes
  the largest collection protocol.
- The prediction is therefore an upper bound. `synthesizeGeneratorMsil` pads
  the generator class with unused `__pad_<n>` fields up to it, which keeps
  every later FieldDef token where Pass 1 put it. It still panics if the real
  count exceeds the prediction. This is the same contract the async state
  machine path already uses (#6515).

## `--target jvm`: `VerifyError` in `$Gen.run`

The build succeeded, but the class failed verification with `VerifyError:
Expecting to find integer on stack`. There were two causes:

- `lowerGeneratorBody` loaded each parameter into a slot but never recorded
  its declared element type, generic arguments, or unsignedness, which
  `lowerFuncScoped` does for an ordinary function. So `for it in items` over
  a `List[Int]` parameter had nothing to narrow the element against, and
  bound `it` as an erased `Object`. The generator body now records the same
  parameter metadata.
- `lowerAsyncGenerator` boxes each yielded value by the generator's declared
  element type (`Integer.valueOf(I)` for `Int`), whatever the yielded
  expression's type actually was. `yield` now coerces its operand to that
  type first, through `coerceValueTo` and the new `FuncCtx.genElemTy`. The
  element type comes from one helper, `generatorElemJvmType`, which is used
  both for the body context and for `LGenFunc.elemType`, so the two cannot
  drift. An erased operand is now unboxed rather than passed to a primitive
  box call.

## Tests

The new dual-target `lyric-compiler/lyric/generator_for_loop_self_test.l`
has 12 cases:

- a `for` over a `List[Int]` parameter and over a `List[String]` parameter
- half-open and closed ranges
- nested loops
- `break` after a yield, followed by a yield after the loop
- `continue`
- a tuple pattern
- loops over a map's keys and entries (`mapKeys` / `mapEntries`)
- a loop over another generator
- a loop-carried accumulator
- a record declared after every generator, which checks the FieldDef token
  prediction

The file is wired into `compiler-self-tests-batch.sh` (dotnet) and
`jvm-generics-self-tests-batch.sh` (jvm).
`generator_closure_var_capture_self_test.l` also gains a `for`-loop variant
of its list-accumulation case. The index-walking case stays.

Before the fix, the dotnet build panicked, and on the JVM every generator
that looped over a typed collection parameter failed class verification.
