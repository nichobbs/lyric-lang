# Integer overflow panics in debug builds and wraps in release builds (D163, #6263, docs/67 G1)

`docs/01` §2.1 said integer overflow panics in a debug build and wraps in a
release build, but no backend read the build profile: unconstrained `Int`
arithmetic wrapped on every target in every build. D163 settles the semantics
and this change implements them on dotnet, the JVM and native.

## Semantics

- `+`, `-`, `*`, unary `-`, and `+=` / `-=` / `*=` on `Byte`, `Int`, `Long`,
  `UInt` and `ULong` panic with `arithmetic overflow: <type> <operation>` in
  a debug build and wrap in a release build. The message is the same on every
  target (`System.Exception` on .NET, `RuntimeException` on the JVM, a
  `lyric panic` abort on native).
- `.wrappingAdd(y)`, `.wrappingSub(y)`, `.wrappingMul(y)` and `.wrappingNeg()`
  wrap in every build.
- The standard library always wraps, and the toolchain (compiler and shipped
  stdlib) is built with the release profile. `lyric bench` builds with the
  release profile too, so benchmarks time what a release build runs.

## Implementation

- The type checker records each such operator with its exact type
  (`SymbolTable.overflowSites`), and, for a compound assignment whose target
  is not a side-effect-free path (`xs[f()] += 1`), the types of the target's
  receiver and index (`overflowCompoundTemps`). It types the wrapping
  methods.
- `Lyric.Pipeline.pipeParseAndErase`, which every target and build path runs,
  marks a file whose resolved `build_profile` is `release`, or whose package
  is `Std.*`, as wrapping.
- `Lyric.ContractElaborator.lowerOverflowChecks` (shared pipeline, after the
  record-arithmetic pass) rewrites each site of a checked file into the
  wrapping operation plus an overflow test and a `panic`, binding each
  operand once to a typed temporary. Signed add/sub test the result's sign
  against the operands'; `Int`, `UInt` and `Byte` products are computed in
  the next wider type; a `Long` product is tested by division (with the
  `MinValue * -1` case apart); unsigned add/sub compare the result, spelling
  the operands through `.toUInt()` / `.toULong()` so every backend compares
  them unsigned. The wrapping methods become the plain operator in every
  build. No backend changed.

## Verification

- `overflow_self_test.l` (dotnet, JVM, native): results up to each type's
  limit, mixed widths, the wrapping methods, and single evaluation of operands
  and compound targets.
- `overflow_panic_self_test.l` (dotnet, JVM): every type and operation panics
  with its message, including compound and indexed compound assignment, and
  the `UInt` / `ULong` cases, which native does not support yet.
- `scripts/ci/overflow-profile-e2e.sh`: a debug build panics and a
  `--release` build wraps, on all three targets.
