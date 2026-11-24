# A method call on a Result or Option that names a plain function is typed as that call (docs/70 phase 3a, #8613)

**Status:** shipped; the type checker.

## Context

`r.mapTwice()` with `func mapTwice(r: in Result[Int, String]): Int` is accepted (the language reference lets a plain function bind by method syntax where the receiver's members are a fixed set, and `scripts/ci/monad-unknown-member-negative-test.sh` pins that it is not T0113), and every backend lowers it as `mapTwice(r)`. The checker recorded neither a callee nor a type for it: `resolveMethodCallPick` bound a plain function only for a primitive receiver, so the call fell to the member-access fallback, which answers a silent `TyError`. Under the gate (D347) that is I0002, "no usable type for an expression the checker could not type", and the monad-unknown-member job failed.

## Decision

`receiverBindsPlainFunctions` also holds for a `Std.Core` `Result` or `Option` receiver. The call resolves to the plain function through the same pick the primitive case uses, so it has its callee, its signature and its result type.

## Consequences

`r.mapTwice()` builds as a TIR call of `mapTwice`. The other receiver types keep their rule (a method, or a dot-named function). Test: `monad_plain_function_method_call` in `scripts/ci/tir-builder-shapes-e2e.sh` (built and run), and `monad-unknown-member-negative-test.sh` (its `good.l`).
