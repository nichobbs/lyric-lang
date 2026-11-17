# D495 - A list literal typed as a slice and used as a fixed array is an array literal (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

With no array context (an explicit type argument, `firstOf[Int]([7, 8], ...)`, or an operand the checker hoisted out of a `?` expression), the checker types a list literal as `slice[T]`, then accepts it where `array[N, T]` is expected. The builder had no conversion from a slice to an array, so each such call was counted as "an argument conversion" (I0002), about five self-test sites.

## Decision

`convertValue` retypes a list literal (`XListLit`) whose type is a slice, when the wanted type is `array[N, T]` with `N` known and equal to the literal's element count: the same node at the array type, each element converted to `T` (so `[7, 8]` at `array[2, Long]` widens each element). A literal of another length, or any non-literal slice, stays counted: a slice value has no length the builder can check.

## Results

`tir_build_self_test.l` builds `firstOf[Long]([7, 8], 1)` with 0 I0002 and 0 I0003.
