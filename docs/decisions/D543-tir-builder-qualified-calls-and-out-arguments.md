# D543 - Qualified and static calls, out and inout arguments (docs/70 phase 3a, #8613)

**Status:** shipped; extends D542.

## Context

The first census totals by kind (D542) ranked what keeps bodies from building. The
largest was `a package-qualified or static call` (168 nodes), then `an res or inout
argument` (41): the checker had recorded both calls' callee and signature, and the
builder refused them.

## Decision

1. A call whose callee is a member path (`Pkg.f(x)`, `Type.f(x)`) and whose
   callee and signature the checker recorded (`calleeByNode`, `callSigByNode`) and
   that is not a method call (`methodCallByNode`) builds as a direct call, as a bare
   name does. A method call keeps its own route, so the receiver is still first.
2. An `out` or `inout` argument builds as a place (`buildPlace`: a local, a field or
   an element) wrapped as `TArgOut` or `TArgInout`; the verifier then checks the
   place's type against the parameter's.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 809 -> 913 of 1165
(I0002 356 -> 252), I0003 0. Next by count: a name that is not a local (77), a
defaulted argument (70), a method, constructor or member call (58), a `for` loop
(40), a method call with no declared receiver (38), a function with no symbol (37),
a binding pattern (35).
