# D459 - A type-test pattern builds (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`case p is Point -> p.x` narrows the scrutinee to `Point`: the checker types the inner pattern (and the binding it introduces) at the tested type. TIR has a `TpTypeTest(inner, ty)` pattern, but the builder had no case for the parser's `PTypeTest`, so every body with a type-test pattern was counted (I0002), and so was the body reading the binding (the binding had no declaration, "a name that is not a local").

## Decision

`PTypeTest(inner, _)` builds as `TpTypeTest` of the built inner pattern at the inner pattern's own type, which is the tested type the checker recorded. The verifier already checks the type is closed and visits the inner pattern.

## Results

`tir_build_self_test.l` builds a record type-test with a body that reads a field of the narrowed binding.
