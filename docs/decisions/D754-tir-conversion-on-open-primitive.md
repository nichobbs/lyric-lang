# A numeric conversion on a primitive an untyped host chain returns is the built-in (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

`JCharacter.toUpperCase(97.toChar()).toInt()` (`auto_ffi_jvm_self_test`, 893) was stopped by the TIR gate (D347) as "a call the checker did not resolve". `toUpperCase` is overloaded on `char` and `int` with different results, so the checker leaves the call untyped (docs/01 section 2.11) and records no built-in for the `.toInt()` that follows; the builder types the inner chain itself from the host metadata (D444, narrowed by the arguments' types), but had no case for a conversion member on that primitive.

## Decision

A call to `toInt`, `toLong`, `toDouble`, `toFloat` or `toChar` with no arguments, whose receiver the checker recorded no type for and the builder types (`openHostChainTy`) as a numeric primitive or `Char`, is that primitive's own built-in call (`Char.toInt`), as it is where the checker typed the receiver. Any other shape is unchanged and counted.

## Consequences

`auto_ffi_jvm_self_test` builds all 70 bodies with the fixture jar. Test: `tir_build_self_test.l`.
