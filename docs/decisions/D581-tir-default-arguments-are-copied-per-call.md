# D581 - A default argument that is a call is built from the declaration and numbered afresh at each call (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361 and D575.

## Context

A call that leaves out a defaulted parameter takes the declaration's default expression. The builder built only a literal or a name there and counted every other default as `a default argument that is not a literal or a name` (142 sites in the compiler area, 36 in the ecosystem, 5 in the standard-library tests). The defaults that occur are calls (`newList()`, `newMap()`, `emptyInvariantBoundary()`).

## Decision

- A default is built from the checker's record of its own package (its call, constructor and type tables are keyed by the declaration's node ids), so the expression is built with `buildExpr` under the parameter's type, which fixes a generic call's type arguments.
- The built tree is then copied with every node numbered afresh (`refreshDefaultIds`) and its spans set to the call. A default stands at every call that leaves it out, and the verifier requires node ids unique within a body.
- The copy handles the kinds a default is made of: literals, global names, calls by value, constructions, conversions, list literals and tuples. Any other kind (a lambda, a block, an `if`) is counted as `a default argument of a shape not yet built`, not guessed.
- A default declared in another package is not built here: the callee package's tables are not this package's, and a default read with the wrong table would be silently wrong. It is counted as `a default argument declared in another package`. A literal or a name keeps its earlier path. The cross-package case needs the package interface to carry the default as data (docs/70 section 8) and is left to that phase.

## Measured

`tir_build` 140, `tir_verify` 27 and `typechecker` 1145 pass; a new case calls one defaulted function twice in a body and verifies the result with no node-unique report. Wide census before and after: compiler 11357 to 11399 bodies built (I0002 1210 to 1170), ecosystem 2536 to 2556, stdlib tests 1142 to 1145, I0003 0 in all three. The default-argument kind was 142 (compiler), 36 (ecosystem), 5 (stdlib); what remains is only `a default argument declared in another package`: 62 in the compiler, 4 in the ecosystem, none in the stdlib tests.
