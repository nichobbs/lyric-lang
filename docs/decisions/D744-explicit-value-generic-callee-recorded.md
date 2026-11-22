# `f[3](a)` on a value-generic function records its callee (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

A value-generic function under explicit generic arguments (`totalOf[3](a)`) returned from `checkExplicitTypeArgCall` before any callee was recorded, so the typed IR had no signature for the call (`fixed_array_self_test.l:631`).

## Decision

`checkExplicitTypeArgCall` records the callee under the call's node (`recordTypeAppliedCallee`) before returning for a value-generic callee, as `f[A](x)` records its own.

## Results

`fixed_array_self_test.l` 33 of 33.
