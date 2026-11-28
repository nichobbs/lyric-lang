# D883 - The checker type-checks every interface default method body once, in its declaring package

**Status:** accepted, implemented in the type checker (docs/70 phase 3c; fixes #9471)

## Decision

1. **A default method (`IMFunc`) of an interface is checked as a method whose `Self` is the interface.** `checkInterfaceMemberBodies` runs `checkFunctionBody` over each default body in the package that declares the interface, with the interface's own type parameters in scope, the interface (at those parameters) as `Self`, and no field locals (an interface owns no fields). A bare call of another member resolves through the interface's method space, as in an impl.
2. **The inherited copies are still checked.** `Lyric.ImplDefaults` copies the body into each impl that omits the method, and the copy is checked against the impl's target as before (D-progress-774, #8264); the interface-level check is the one that reports an error in the default itself, once, at its own span.
3. **No new diagnostic code.** The ordinary body diagnostics apply (T0020 unknown name, T0060, T0070, T0043 and so on), reported at the default's source.

## Why

Before, a default body no impl inherited was never checked: `nosuchfn(n)` in a default of a library surfaced as the backend's T0123, a type error surfaced only in a consumer that implemented the interface (once per inheriting impl, at the library's span), and the TIR builder had no typed body for the default itself (found while doing #9451, native cross-package defaults).

## Effect

`testdata/reject/default_body_type_error`, `default_body_unresolved_name` and `default_body_generic_interface` fail on dotnet and the JVM with no impl in the program. The checker records a typed body for each default, so a TIR-based backend can read one.
