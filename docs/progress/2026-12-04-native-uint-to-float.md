# Native TIR lowers UInt.toDouble and UInt.toFloat (docs/70 phase 4a, part 8)

Decision: D858.

## What shipped

`lowerNumericConversion` zero-extends a `UInt` before the signed convert; `wrapping.l` covers it in the e2e script.
