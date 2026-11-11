# D574 - Range patterns build as TpRange (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361.

## Context

A range pattern (`case 2 ..= 5 ->`, `case 'a' ..< 'z' ->`, `case -5 ..= -1 ->`) was reported as `a range pattern`, so every function matching on one stayed unbuilt. The native lowering already handles `TpRange` (literal bounds and an inclusive flag), and the phase 4a session reported the gap from a real build.

## Decision

- `PRange(lo, inclusive, hi, _)` builds as `TpRange(lo, hi, inclusive)` when both bounds are literals, possibly parenthesised or negated (`-5`, `-1.5`). A negated integer or float literal is folded to its value, as the checker folds range bounds.
- A bound that is not a literal (a named constant, an expression) is still reported, as `a range pattern bound that is not a literal`.
- The distinction between `..` and `..<` (`bareDotDot`) is source spelling only and is dropped.

## Measured

The `tir_build` self-test passes (130), with a case covering `Int` ranges (negative, half-open, closed) and a `Char` range, each built and verified. The wide census was not re-measured for this change.
