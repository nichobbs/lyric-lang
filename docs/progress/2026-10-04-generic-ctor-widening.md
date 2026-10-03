# Lossless widening through generic constructor arguments and tuple elements (#7813)

After #7805 an implicit lossless widening (`Byte < Int < Long`,
`Byte < UInt < ULong`, `Float < Double`, docs/01 §4.1) applied at every
direct position, but not one level down: with `u: UInt`,
`val a: Option[ULong] = Some(u)`, `val b: (ULong, Int) = (u, 1)` and, with
`i: Int`, `val c: Result[Long, String] = Ok(i)` were all T0060. D169 settles
the rule: a scalar inside a value being built widens to the slot the expected
type fixes; a value already built does not.

## What changed

- **Type checker** (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`).
  `inferExprExpected` pushes the expected slot type into each argument of a
  union-case construction (bare via `inferCaseCtorExpected`, qualified by a
  second pass when the first leaves a widening), of a generic record
  construction (`ctorArgsExpected` / `inferCtorArgsExpected`) and into each
  tuple element. A scalar that widens to its slot is typed at the slot type,
  so the construction adopts the expected instantiation, and is recorded as
  a conversion site of its own chain (`widenedSlotType` →
  `recordWideningSite`, signed and float chains included).
  `Lyric.Mono.desugarCheckedFile` spells it out as `.toLong()` / `.toInt()` /
  `.toDouble()` / `.toUInt()` / `.toULong()` before any backend runs, so the
  instance is built at the expected type on every target and the unsigned
  chain zero-extends.
- **Call arguments.** A case-constructor, generic-record-constructor or tuple
  argument that differs from the selected parameter type only by such
  widenings (`widensStructurally`) is re-checked against it, so
  `takesOpt(Some(i))` for `takesOpt(o: in Option[Long])` is accepted.
- **Inline ranges and array fields.** The expected-typed paths keep #8031's
  range checks and #8042's array-field typing: `inferCaseCtorExpected` notes
  a payload's range at the expected instantiation
  (`noteCaseRangeAgainstExpected`) before the construction records its own
  sites, `inferGenericRecordCtorArgsExpected` notes a generic record field
  the expected instantiation makes a range (previously unchecked) and types
  a bracket literal for an array field (`ctorArrayFieldTypes`), and a tuple
  element records its range slot after widening.
- **Diagnostics.** An existing container value is still rejected (T0060 /
  T0061 / T0043 …); `typeMismatchHint` now explains that widening converts a
  scalar where a value is built, not the contents of an existing one, and
  names the rebuild (`mapOption(value, { x -> x.toULong() })`,
  `mapResult`, `mapResultErr`, or the conversion method).

## Tests

- `lyric-compiler/lyric/generic_ctor_widening_self_test.l` — signed and float
  chains through `Some`/`Ok`/`Err` (bare, qualified, named), generic records
  and unions, tuples, nesting, list literals, `return`, body values, call
  arguments, record fields and assignment, on dotnet, JVM and native.
- `lyric-compiler/lyric/generic_ctor_unsigned_widening_self_test.l` — the
  `Byte < UInt < ULong` chain with `4000000000u32`, asserting zero-extension,
  on dotnet and JVM (native has no unsigned integer types yet).
- `range_refinement_self_test.l` (dotnet, JVM) and
  `scripts/ci/range-refinement-e2e.sh` (every target) — a range slot beside a
  widened one in a tuple, a generic record and a bare or qualified
  `Ok`/`Err`, checked at runtime.
- `typechecker_self_test.l` — widening accepted inside constructions and
  tuples, `Int` → `ULong` still rejected, an existing `Opt[UInt]` / tuple
  value still rejected with the rebuild hint.

Wired into `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh`, `scripts/ilverify-selfhosted.sh`
and (the cross-target file) `scripts/ci/native-backend-self-tests.sh`.
