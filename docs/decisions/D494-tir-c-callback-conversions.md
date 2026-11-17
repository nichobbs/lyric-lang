# D494 - A closure passed to a C callback is `CvCallback`; as a userdata pointer, `CvClosureAsPointer` (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR) and D229 (C callbacks).

## Context

On `--target native` a Lyric closure passed to an `extern func` callback parameter meets a declared C type with one more parameter than the closure has: the userdata slot (`NativeUserdata`, anywhere in the list, or a trailing `NativePtr[Byte]`). The same closure may also be passed as the userdata pointer itself (docs/01 section 11.6). The checker accepts both (`argSatisfiesExternParam`); the builder had no conversion for them, so each call was counted as "an argument conversion" (I0002), about 20 self-test sites.

## Decision

Two `ConvKind`s, both explicit nodes and never a guessed retype:

- `CvCallback`: the operand has the closure type, the node the declared callback type. `isCallbackOf` holds when the callback is the closure's type with exactly one userdata slot inserted (same result, same parameters, same asyncness).
- `CvClosureAsPointer`: the operand has a function type, the node a userdata pointer type.

`convertValue` produces them; the verifier checks both shapes (`convert-type`); the interface format reads and writes them as tags 13 and 14 (append-only).

## Results

`tir_build_self_test.l` builds a call passing one closure as the callback and as the userdata (0 I0002); `tir_verify_self_test.l` covers the accepted and rejected callback shapes.
