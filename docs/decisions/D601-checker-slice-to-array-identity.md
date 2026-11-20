# D601 - `.toArray()` of a slice is typed as the slice (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

docs/01 gives a slice the members `.length`, `.append`, `.concat`, `.slice`, `.toList()` and `.toArray()` (the identity). The checker typed the first five and left `.toArray()` out of the slice member table, so a call on a slice had no callee and no type (a silent error type): the builder counted the body (I0002), and the error type made anything read from the result (`.length`, `.count`) unchecked as well. Sixteen test bodies of `lyric-generator-sdk` were unbuilt, and a misuse the error type hid (`xs.toArray().count`, T0228 on a slice) went unreported.

## Decision

`builtinMember` types `.toArray()` of a `slice[T]` as `() -> slice[T]`, as `.append` and `.concat` are typed, so the call is a built-in of the slice and its result is the slice. Misuse of the result is now reported where it was hidden: the five `.count` reads of `lyric-generator-sdk`'s tests are `.length`, and three bare enum case bindings there (`val sev = Error`, a case name other enums share) carry their type (docs/01 section 2.11).

## Results

`slice_to_array` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` and runs (exit 3). `lyric-generator-sdk`'s tests build all 65 bodies on the JVM (was 49) and pass on both targets.
