# D-progress-960 — Range and distinct values stringify as their underlying value

**Status:** shipped

## Problem

A range subtype or distinct type is lowered to a wrapper class holding one
`value` field. Stringifying one fell through to the host's default:

- `Cents.from(5000).toString()`, `toString(c)`, `"${c}"` and `"x" + c` went
  through the wrapper class's inherited `Object.toString()` on both targets and
  printed the wrapper, never `5000`.
- On MSIL, `Cents.from(5000)` with a `Long`-backed range passed the `Int`
  literal unconverted to a `from(int64)` factory, which ilverify rejects and
  which reads a garbage high word at run time.

Both surfaced in `lyric-ui`'s `ui-customers` example, which renders range
fields into form inputs.

## Decision

A range or distinct value stringifies as its underlying value in every
stringification position, on both targets. A `UInt`/`ULong`-backed type, which
both targets erase to the signed representation, formats unsigned.

- **MSIL.** `stringifiesByValueMsil` treats a distinct class (one with a
  `<cls>/value` entry in `fieldMsilTypes`) like a primitive at the
  `.toString()`, interpolation and concatenation sites;
  `boxIfNeededUnsignedMsil` loads `value` and boxes the underlying type, with
  the unsigned box target for a class in `CodegenCtx.unsignedDistincts`
  (filled from the declared underlying `TypeExpr` at registration). The `from`/`tryFrom` arms
  coerce their argument to the underlying type with `coerceCallArgMsil`.
- **JVM.** Each distinct class registers its `$value` accessor in `funcSigs`;
  `registerInstanceSigErased` now fills `retIsUnsigned` from the declared
  return type (only bare-key lookups read it elsewhere, so instance sigs were
  unaffected before). `coerceToStringForConcat` (interpolation,
  concatenation) unwraps through `$value` and recurses on the underlying type
  with that flag; the free `toString(x)` form routes a reference argument
  through the same helper, and so does the member `.toString()` form unless
  the class registers its own `toString` method.

## Verification

`range_subtype_self_test.l` ("a Long range subtype from an Int literal renders
as its value") covers `.toString()`, interpolation, free `toString`, a record
field of the range type and `tryFrom`; "a UInt range subtype renders its value
unsigned" covers a value above `Int.MAX`. Both run on MSIL and the JVM.
