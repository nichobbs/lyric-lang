# D402 - A call dispatched on a restored non-generic interface skips the owner-argument check (docs/70 phase 3a, #8613)

**Status:** shipped; extends the interface dispatch of a restored package's implementing type (D447).

## Context

A restored package's interface keeps no `impl` member, so a call of a method a restored generic record implements (`Box(v = 1).size(4)`, `impl[T] Sized for Box[T]`) is resolved by the checker to the non-generic interface's declaration, `GiLib::Sized::size`. The builder already dispatches such a call on the interface. But `instantiateMethod` read the receiver's type arguments (`Box[Int]`) as the owners of a member of a generic impl and counted the body ("a method call on a member of a generic impl", I0002), although the callee has no owner generics at all.

## Decision

`instantiateMethod` takes `viaIface`: when the call is a dispatch on a non-generic interface (`ifaceOwnerOfMethod`), the receiver's arguments belong to the receiver's own type and are not instantiated into the callee. The callee is the interface's method with no type arguments, as for a non-generic receiver.

## Results

`restored_generic_impl_call` in `scripts/ci/tir-builder-shapes-e2e.sh` builds the consumer with `--verify-ir` (every body built, verifier clean) and runs it on dotnet and the JVM (exit 8).
