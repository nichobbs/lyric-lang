# D447 - The package interface declares an `impl` member that carries a default (docs/70 phase 3a, #8613)

**Status:** shipped; extends D442 and D482. No change to what the checker accepts and no language change.

## Context

A call on a concrete type takes the default of the `impl` method it resolves to, not the interface's (language reference 6.1; `restored_default_args_self_test.l`). A package carries the defaults of its callables in its interface (D482), found by the callee's DefPath key and the parameter's name. `Sq(s = 4).area()` on a restored `impl Shape for Sq { func area(self: in Sq, scale: in Int = 3) }` was counted ("a default argument declared in another package"): the producer already wrote the member's default under `IdLib::Sq::$impl(Shape)::area(Sq,Int)` and the consumer asked for exactly that key, but the interface held no declaration for the member to carry the default, so the consumer found nothing.

The cause was the interface walk (`addItem`): it passes only visible items on to `addVisibleItem`, and an `impl` has no visibility of its own, so no `impl` member was ever declared.

## Decision

`addImplDefaults` runs from `addItem`, before the visibility gate. For a non-generic `impl` it declares each member that has a parameter with a default, as a public method at the member's DefPath (the resolver's: the target, then `$impl(Interface)`, then the method), typed against the impl's target as `Self`. A generic `impl` exports no defaults (#8099), as before. Members with no default are not declared yet: nothing reads them (docs/70 section 9 adds them with the member signatures).

The producer's key and the consumer's callee key were already equal, so neither changes.

## Not a possibility

Two impls of one type that share a method name are rejected by the checker (T0139), so the keys of two such members never meet. Two types that implement the same interface method keep their own defaults, which `restored_impl_defaults` in `tir-builder-shapes-e2e.sh` checks on dotnet and the JVM (`4 * 3 + 5 * 7 + 5 * 2`).
