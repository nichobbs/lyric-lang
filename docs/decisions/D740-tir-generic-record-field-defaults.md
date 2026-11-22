# The field defaults of a generic record that mention none of its parameters are carried in its interface (docs/70 phase 3a, #8613)

**Status:** shipped; builder (the package defaults the interface carries).

## Context

`pub generic[T] record Box { item: T; policy: RetryPolicy = lenientRetry() }` constructed in another package as `Box(item = 1)` leaves `policy` to its default. `noteFieldDefaults` returned early for a generic record, so its field defaults were never built and the interface carried none: the consumer found no default to read and the TIR gate (D347) stopped the body (`Df.C::main` of `llvm_project_self_test.l`).

## Decision

A generic record's field defaults are built under the record's own type parameters, and each one that mentions none of them (in its type, a callee's type arguments or any part) is carried in the interface, as a non-generic record's is. A default that does mention one (`None` for a field of `Option[T]`) is not carried and is counted at the consumer as before, since it would need each use's instantiation.

## Results

`llvm_project_self_test.l` (50 of 50 on native): the `Df` project builds `Box(item = 1)` with the carried default.
