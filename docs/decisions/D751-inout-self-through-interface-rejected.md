# An `inout Self` parameter cannot be called through an interface (T0232) (docs/70 phase 3a, #8613)

**Status:** shipped. Owner decision, 2026-11-22.

## Context

`interface Absorber { func absorb(self: in Self, other: inout Self): Int }` implemented for a record `Box`: `val a: Absorber = Box(n = 3); a.absorb(other)` with `other: Box` type-checked, because the checker substitutes `Self` with the receiver's type, the interface, and a `Box` argument was accepted where the interface was expected. For an `in` parameter that is an upcast and sound. For an `inout` or `out` parameter the callee writes a value back into the argument variable, and the implementer can write only its own type, so passing a `Box` variable by reference where an interface-typed parameter is expected can leave a different implementer's value in a `Box` variable, or a `Box` variable holding a non-`Box`. The typed IR verifier rejected the program (I0003), which is the first place the unsoundness showed.

## Decision

Calling an interface method that has an `out` or `inout` parameter whose type mentions `Self`, through a value whose type is the interface, is the checker error T0232. `in` parameters of `Self` through an interface stay allowed (an upcast), and a call through a value of the concrete implementing type stays allowed: its signature is the impl's, with `Box` where the interface said `Self`. No language syntax changes.

## Consequences

`impl_self_spelling_self_test` calls the `inout` method through a `Box`-typed value; the compile-fail corpus has `inout_self_through_interface`. docs/01 section 2.12 states the rule and the book's diagnostics table lists T0232.
