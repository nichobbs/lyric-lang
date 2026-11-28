# The checker type-checks every interface default method body (docs/70 phase 3c, D883)

## What shipped

- `checkInterfaceMemberBodies` (`typechecker_checker.l`) checks each default method body once, in the declaring package, as a method whose `Self` is the interface (D883, fixes #9471). A bad default in a library is reported by the library's own build, at the default's span, instead of per inheriting impl in a consumer or as a backend T0123.
- `testdata/reject/default_body_type_error` (T0060), `default_body_unresolved_name` (T0020) and `default_body_generic_interface` (T0070, `T` is rigid in a generic interface's default): each fails on dotnet and the JVM with no impl at all.
