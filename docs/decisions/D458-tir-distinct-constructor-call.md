# D458 - A distinct type's constructor call builds as a wrap (docs/70 phase 3a, #8613)

**Status:** shipped; extends the `T.from(x)` factory (`buildDistinctFactory`).

## Context

`TestAge(40)`, the constructor call of a distinct type `type TestAge = Int`, is typed by the checker (`distinctCtorType`) without a recorded callee, so the builder counted every one as "a call the checker did not resolve" (I0002): `Lyric.DerivesSelfTest`, `Pu.Main`-style programs and others.

## Decision

`buildDistinctFactory`, which builds `T.from(x)` as a `CvWrapDistinct` conversion of the argument converted to the underlying type, also builds the bare call `T(x)` whose result type is a non-generic distinct type. The call reaches it only when no callee was recorded, so a function of that name is never taken for a constructor.

## Results

`tir_build_self_test.l` builds `TestAge(40)` and a record construction taking one, with every body built and a clean verifier.
