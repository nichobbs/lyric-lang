# D178 - Value generic parameters on protected types

**Status:** accepted

Settles the protected-type half of D169's follow-up (#8149). Builds on D176 (generic protected types on native).

## Context

D169, D173 and D175 let a record's, opaque type's or union's value generic parameter size its array fields. A record's methods are hoisted into value-generic free functions that `Lyric.Mono` specialises per length. That route does not fit a protected type: its entries and funcs run under the instance lock, may carry `when:` barriers and read the fields by bare name, and hoisting them into free functions would drop the lock.

## Decision

1. **Specialise the whole declaration per length, on every target.** The middle end views a protected type as a record (fields, invariants, and each entry or func as a method, an entry told by a marker annotation), runs the existing value-generic record passes over it, and puts the result back as a protected type. `Ring[3]` becomes `Ring__V3`, a non-generic protected type with `N` replaced by `3` in its field types and its member bodies. A construction binds each length from an array argument or the expected type, as a record's does. Dotnet and the JVM do not erase a protected type's value parameters: the members read the length by name, so they need the specialisation.
2. **The checker** accepts the parameter on a protected type, binds it as an `Int` constant in each member body, and records constructions as it does for records.
3. **Backends.** Dotnet needs no change. The JVM registers its signatures before the middle end, so it registers the per-length protected types, and the functions whose signatures name one, again from the post-middle-end file. Native registers a protected member under its receiver's type name too, so two specialisations that share a member name each reach their own.
4. **Not shared across packages yet.** A protected type with a value generic parameter cannot be `pub` (T0168): another package could only use it by specialising it again at a new length in the declaring package, or by naming a specialisation the declaring package made, which needs the backends' pre-middle-end registries to learn a sibling package's specialised signatures. That is follow-up work; the restriction makes the unsupported shape a compile error instead of a run-time failure.

## Tests

`value_generic_protected_self_test.l` on dotnet, the JVM and native; the checker self-test for T0168 and for the accepted declaration.
