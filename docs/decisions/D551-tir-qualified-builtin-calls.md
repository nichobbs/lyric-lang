# D551 - A package-qualified built-in call is recorded as the built-in (docs/70 phase 3a, #8613)

**Status:** shipped; extends D362 and D550.

## Context

The sites D550 added showed that the largest part of `a call the checker did not resolve`
(24) was `Console.println(...)`, written through a package name, an import alias or the
full path. The checker already types such a call as the codegen built-in (`println`):
`qualifiedBuiltinCalleeType` finds the real function of that name in the package the
qualifier names and answers the built-in's type, because the path itself has no type. But
the call was recorded neither as a built-in (`builtinByNode` was filled only for a
single-segment name) nor with a callee, so the TIR builder had nothing to build.

## Decision

`recordBuiltinCall` records a call whose callee is a path of two or more segments, whose
type is the checker's own error and which `qualifiedBuiltinCalleeType` types as a built-in,
as that built-in under the call's `NodeId`, named by the last segment. Only the TIR builder
reads `builtinByNode`; the backends keep their own lookup, so nothing they emit changes.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 965 -> 967 of 1165, I0003 0,
`a call the checker did not resolve` 24 -> 20. What remains in that kind starts with
`Age.tryFrom(25)` (a distinct type's factory, `book_ch02_tests.l:53`). Next by count: a name
that is not a local (75, the cascade), a method, constructor or member call (58), a method
call with no declared receiver (39: protected-type entries, which the TIR has no kind for;
modelling them is a design decision for the owner), an argument conversion (37), a function
with no symbol (37).

## Tests

The `tir_build` self-test harness has no stdlib, so the case is covered by the stdlib
census (`Console.println` is in most of its programs) and a real `lyric build --verify-ir` of
the three spellings, each of which builds both bodies and verifies.
