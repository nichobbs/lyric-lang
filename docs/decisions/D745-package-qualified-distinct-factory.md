# `Pkg.Type.from(x)` types as the distinct factory (docs/70 phase 3a, #8613)

**Status:** shipped; checker (the typed IR half is D748).

## Context

`distinctFactoryType` took only a single-segment type name, so `Lyric.DistinctOpsSelfTest.Cents.from(15i64)` (a name qualified by the file's own package, #7546) had no type.

## Decision

The receiver is flattened to its path segments; a qualified one looks the type up in the named package (`symTableTryFindInPackage`), the single-segment form as before.

## Results

`distinct_ops_self_test.l` 9 of 9 with D748.
