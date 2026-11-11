# D568 - Conversion methods on refined and distinct values, and stubbable interface callees (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361, D563 and D567.

## Context

Two more calls the checker accepts left bodies unbuilt. A numeric conversion method on a range-subtype
or distinct value (`a.toInt()` with `a: Age`) is typed at the primitive and records no callee, since the
conversion-method intrinsic is recognised only for primitive receivers. And a call of a method of a
`@stubbable` interface (`feed.priceOf(sym)`) recorded no callee either: the stub rewrite builds the
stub's `impl` method with the span of the interface member it stands for, so two method declarations
shared one `methodDeclBySpan` key and `symTableMethodDeclId` returned nothing for a count other than one.

## Decision

- A call `x.toInt()` (also `toByte`, `toLong`, `toChar`, `toDouble`, `toFloat`, `toNat`) with no arguments
  on a range-subtype value builds as `CvUnrefine` of the value, and on a non-generic distinct value as
  `CvUnwrapDistinct`, then converted to the call's type by the usual rules (widening). A generic distinct
  value, or a result the usual conversions do not reach, is reported.
- `symTableMethodDeclId` takes the receiver's owner name. When several method declarations share a span
  it picks the single one whose DefPath owner segment is that name, so the interface's method wins over
  the stub impl's; otherwise it still returns nothing.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D567: bodies built 1082 -> 1084 of 1165,
I0003 0; `a call the checker did not resolve` 10 -> 4 (what is left: chained extern calls, whose host
result the checker leaves unchecked, D359). The typechecker self-test passes (1145). Sites left in the
branch/member-call kinds are in plugin-generated code (`storeProvider`, `pluginDecodeStoreGrant`) and one
`try` used as a value (`runScopeTest`), which TIR has no node for.
