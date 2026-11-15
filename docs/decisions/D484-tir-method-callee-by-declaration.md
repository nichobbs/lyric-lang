# D484 - A method call names the declaration the checker resolved, not a dot-named function of the same arity (docs/70 phase 3a, #9106)

**Status:** shipped; extends D483.

## Context

`recordMethodCalleeNode` recorded the callee of `e.m(...)` by looking for a dot-named function `Oe.m` first, with a lenient match
(same name and same parameter count) for a signature no declaration of the package has at its span (a dependency's). A record
method `m(self, x, y)` beside `func Oe.m(o, x)` has a receiver-dropped signature of two parameters, so `e.m(1, 2)` took the
dot-named function's symbol: TIR had a three-argument call to a two-parameter function (#9106, the #8098 shape; native 4a part 4
found it, and its lowering refuses such a call meanwhile).

## Decision

The callee is the first of: the dot-named function whose declaration is at the signature's span, the method declared at the
signature's span (`symTableMethodDeclId`), and only then the same-named dot-named function of the package with the signature's
parameter count (the dependency fallback). A declaration the checker resolved to is never replaced by one of another arity.

## Results

`scripts/ci/tir-builder-shapes-e2e.sh` gains `method_beside_dot_named` (`e.m(1) + e.m(1, 2)` builds with `--verify-ir`, 0 I0003,
and runs: 91 + 83). Compiler census (dotnet) 12684 of 12824 bodies built, I0003 0.
