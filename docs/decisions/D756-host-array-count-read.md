# `.count` on a host array local builds as its length (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder.

## Context

`val direct = enc.GetBytes("hi")` then `direct.count`: the local holds a host array result, which the checker leaves unchecked, so `.count` is not the typed-slice error T0228; the builder had no member form for it (`auto_ffi_self_test.l`).

## Decision

A `count` read of a local whose declared type is a slice or an array is the built-in `slice.length` / `array.length` (`openLocalBuiltinProperty`); a string's `count` stays unbuilt.

## Results

`auto_ffi_self_test.l`: the `GetBytes` case builds.
