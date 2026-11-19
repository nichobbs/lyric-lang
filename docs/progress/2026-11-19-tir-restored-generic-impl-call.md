# docs/70 phase 3a: a call dispatched on a restored non-generic interface skips the owner-argument check (D402)

A call of a method a restored package's generic record implements (`impl[T] Sized for Box[T]`) resolves to the interface's declaration and dispatches on it; the receiver's type arguments are no longer read as the callee's owner generics, so the body is no longer counted (I0002). New shape `restored_generic_impl_call` (dotnet, JVM).
