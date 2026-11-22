# `inout Self` through an interface is a checker error (D751)

Calling an interface method with an `out` or `inout` parameter whose type mentions `Self` through an interface-typed value, with an argument not of the interface type, is T0232; calls on the concrete type and `in Self` parameters are unchanged. Clears the `impl_self_spelling` I0003 (the unsound by-reference upcast). Self-test: `impl_self_spelling_self_test.l`; reject case `inout_self_through_interface`.
