# D-progress-890 — MSIL: `UInt`/`ULong` gain a real representation (erasure to `Int`/`Long`, mirroring the JVM backend), fixing the CLR-loader crash and the downstream `u16`/`u32`/`u64` list-literal miscompile (#6756, #6782)

**Status:** shipped

**Context.** `UInt`/`ULong`-backed types (plain distinct types and range
subtypes) worked correctly on `--target jvm` (erased to `int`/`long`, with
unsigned-aware comparison/division/toString — #6661/#6695/#6748), but
`--target dotnet` had no MSIL representation for `UInt`/`ULong` at all:
`Msil.Codegen.typeExprToMsilCtx` had no `UInt`/`ULong` arm, so construction
fell through to "user type in this package" (`MClass`) — a nonexistent
class — and crashed the CLR loader with "Common Language Runtime detected
an invalid program" at run time (#6756).

**Fix — type-expression erasure.** Added `UInt -> MInt` / `ULong -> MLong`
arms to `typeExprToMsilCtx`, mirroring the pre-existing `Nat -> MLong`
precedent immediately above them and the JVM backend's identical
`UInt -> JInt`/`ULong -> JLong` erasure: `UInt`/`ULong` occupy the SAME
32-/64-bit slot a signed `Int`/`Long` uses, they just interpret the bit
pattern differently for arithmetic that cares about sign. A new
`isUnsignedTypeExprMsil` helper (mirroring JVM's `isUnsignedTypeExpr`)
recognizes a `TRef`/`TRefined`/`TParen`-wrapped `UInt`/`ULong` type
expression for callers that need to know a type is unsigned-flavored, since
the erased `MsilType` alone can't distinguish it from a signed `Int`/`Long`.

**Fix — literal lowering (`u32` specifically).** A `u16` literal already
lowered correctly by luck (its magnitude always fits `Int32`'s positive
range, so the pre-existing "does this fit Int32?" branch took the `MInt`
path). A `u32` literal did NOT: `Msil.Codegen`'s five `LInt` suffix-match
sites (the untyped-static-val predictor, the list-literal element-type
predictor, the real `ELiteral` lowering, the literal-pattern-match lowering,
and the literal-foldability check) all treated any `u32` value exceeding
`Int32.MaxValue` (e.g. `2500000000u32`, a valid in-range `UInt`) as
requiring 64-bit (`MLong`) storage — but `UInt`'s erased field/local/param
slot is `Int32`, not `Int64`, so a value like `2500000000u32` bound to a
`val x: UInt` pushed an 8-byte `ldc.i8` onto the stack against a 4-byte
`Int32` slot, invalid IL. Added an explicit `U32` arm to all five sites:
the literal always lowers to `MInt`, using a new `int32BitsOfUnsignedMsil`
helper (`Msil.Lowering`, alongside `emitDistinctBoundsToFail` which needs
the identical wrap) that takes the low 32 bits and reinterprets them as
signed (mirroring C#'s `unchecked((int)v)`) rather than `longToInt`, whose
`OverflowException`-on-out-of-Int32-range behaviour is correct for a
genuinely out-of-range SIGNED value but would PANIC THE COMPILER ITSELF
when narrowing a merely-large UNSIGNED one whose bit pattern already fits
32 bits. `u64` needed no equivalent fix — `I64`/`U64` already share one
`MLong`/`ldc.i8` arm at every site, and a raw 64-bit bit pattern is
representation-agnostic between signed and unsigned interpretations.

**Fix — distinct/range-subtype bounds checking.** Added `isUnsigned: Bool`
to `MDistinctType` (mirroring JVM's `LDistinctType.isUnsigned`), threaded
through `mkDistinctTypeIR`/`mkDistinctRanged` and set at the `IDistinctType`
codegen site via `isUnsignedTypeExprMsil(decl.underlying)`.
`emitDistinctBoundsToFail` (`Msil.Lowering`) now branches on it: the `MInt`
bound-loading arm uses `int32BitsOfUnsignedMsil` instead of `longToInt` when
unsigned (a `UInt` bound like `4000000000` exceeds `Int32.MaxValue` and
would otherwise panic the COMPILER while building the very method that
checks it), and the comparisons use the ALREADY-EXISTING-BUT-UNUSED
`emitClt_Un`/`emitCgt_Un` opcode emitters (`Msil.Opcodes`) instead of the
plain signed `emitClt`/`emitCgt` — a signed comparison misreads any
in-range value at or above 2^31 (`UInt`) as negative, silently failing
bounds checks for legitimate values whose sign bit happens to be set (the
exact #6661 defect class JVM fixed, now closed on MSIL too).

**#6782 (list literals) — resolved as a direct consequence.** `#6782`
tracked `listLiteralElemTypeMsil` mis-inferring `u16`/`u32`/`u64` list
literal element types (`[1u16, 2u16][0] + [1u16, 2u16][1]` crashed with
`InvalidProgramException`, confirmed by reproduction). The root cause was
the SAME predicted-vs-actual divergence this fix eliminates: the predictor
returned `MObject` for `u16`/`u32`/`u64` (falling back to the "legacy"
boxed `List<object>` path), while the REAL literal lowering pushed a raw
unboxed `MInt`/`MLong` value with no `box` instruction — a stack-type
mismatch. Once the literal lowering and the predictor both agree on
`MInt`/`MLong` (this fix), `[1u16, 2u16]` naturally takes the SAME
homogeneous-typed-array fast path a plain `[1, 2]` `Int` literal already
did — no `listLiteralElemTypeMsil`-specific fix was needed beyond adding
the `U16`/`U32`/`U64` arms (mirroring JVM's #6631/#6741 fix to
`listLiteralElemTypeJvm`) once the underlying erasure existed.

**Scope note — bare-scalar comparison/division/stringification stay
signed.** This fix's `isUnsignedTypeExprMsil` is the seam a future
`fctx.unsignedVars`-style side table (mirroring JVM's `ctx.unsignedVars`/
`isUnsignedExpr`, #6754) would consult, but no such table exists on MSIL
yet — only `MDistinctType.isUnsigned`-gated bounds-checking consumes
"unsigned-ness" today. A BARE `val x: UInt = 2500000000u32; println(x)`
now compiles and runs (no crash) but prints the SIGNED interpretation
(`-1794967296`), and `x < y`/`x / y` on two bare `UInt` locals use plain
signed `clt`/`div` rather than `.un` opcodes — both wrong for a genuinely
sign-bit-set value, matching neither `UInt`'s declared semantics nor the
JVM backend's behavior for the same program. This is a real, scoped gap,
not a corner cut silently: general bare-scalar `UInt`/`ULong` comparison/
division/stringification needs the FULL JVM-mirroring side-channel
(`unsignedVars` populated at every param/`val`/`var`/`let` binding site,
consulted by every `BLt`/`BGt`/`BLte`/`BGte`/`BDiv`/`BMod`/`println`/string-
interpolation call site JVM's `isUnsignedExpr` covers) — a larger, separable
follow-up filed as #6913, out of scope for this fix (which closes the
crash-class bugs #6756/#6782 actually reported and is fully covered by
regression tests).

**Coverage.** Moved the `UInt`/`ULong` cases out of the now-JVM-only
`range_subtype_unsigned_jvm_self_test.l` into the dual-target
`range_subtype_self_test.l` (already wired on both `--target dotnet` and
`--target jvm`); the former file, now containing only its unrelated
`Float`-backed `.toFloat()` JVM-only case, is renamed
`range_subtype_float_jvm_self_test.l` (`ci.yml`'s one JVM step for it
updated to the new path — no new CI step added). Verified against a
from-source `make lyric` build: `range_subtype_self_test.l` green on both
targets (18/18), including the moved `UInt`/`ULong` cases; manual repros of
both issues' exact reported crashes (`2500000000u32` construction,
`[1u16, 2u16][0] + [1u16, 2u16][1]`, and the `u32`/`u64` list-literal
analogs) now run and print the correct value instead of crashing.

**Related:** #6756, #6782, #6913 (bare-scalar unsigned-aware
comparison/division/stringification follow-up), #6661/#6695/#6748 (the JVM
backend's prior, now-mirrored fixes).

**Follow-up (#6973, review REQUIRED).** #6782's own fix instructions
specified two parts: fix `listLiteralElemTypeMsil`, then add an MSIL-target
regression test — this entry's original text only did the first half,
verifying the second by hand instead of with an automated test. Added
`u16`/`u32`/`u64` cases to the dual-target `list_literal_index_self_test.l`
(the established home for this defect family, alongside `#5620`'s original
`Int` case and its siblings) rather than widening the JVM-directory
`list_literal_uint_elem_jvm_self_test.l` cross-target; corrected that
file's header, which still claimed "`UInt`/`ULong` have no MSIL
representation at all... do not run this file with `--target dotnet`" —
now false. Verified on both targets against a from-source `make lyric`
build (7/7 in `list_literal_index_self_test.l` on `--target dotnet` and
`--target jvm`). A `u32` case using a magnitude above `Int32.MaxValue`
(exercising the `int32BitsOfUnsignedMsil` narrowing path specifically) was
tried first but hit an unrelated, pre-existing JVM gap (`Jvm.Codegen`'s
"`+` on two operands whose runtime type is fully erased to Object" guard)
— narrowed to the same in-range magnitude the pre-existing JVM-only test
already uses, since that MSIL-specific narrowing detail is already covered
by `range_subtype_self_test.l`'s `UInt`-backed sign-bit-boundary case.

**Follow-up (#6985/#6986, review REQUIRED).** Repeated rebase-driven
renumbering (this entry has moved from D-progress-878, to D-progress-882,
to D-progress-883, to its current D-progress-890, each time `main` advanced
with an unrelated entry already claiming the prior number) left
`docs/10-bootstrap-progress.md`'s own cross-reference pointing at a stale
number more than once — corrected each time, most recently to
D-progress-890 (this decision-log restructure move). Separately, three
places outside this PR's own diff still asserted "`UInt`/`ULong` have no
MSIL representation at all", directly contradicted by this fix: a
production doc comment (`lyric-compiler/jvm/codegen/06_items.l`'s
`mkJvmDistinctTypeIR`) and two JVM-only test file headers
(`unsigned_int_ops_jvm_self_test.l`, `generic_uint_erasure_jvm_self_test.l`)
— two of which cited the file this PR deletes
(`range_subtype_unsigned_jvm_self_test.l`) as their own justification.
Corrected all three: the first two now correctly scope their still-real
JVM-only status to their OWN narrower defect classes (bare-scalar
unsigned-aware arithmetic, `#6913`; a JVM-only generic-arg bookkeeping
choke point with no MSIL analog since MSIL's generics aren't type-erased)
rather than the now-false "no MSIL representation at all" claim (#6986).
