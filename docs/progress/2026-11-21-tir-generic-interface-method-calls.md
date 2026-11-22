# Checker and builder: an interface method with type parameters of its own (D687)

`e.id(5)` on an interface-typed value, `func id[U](self: in Self, x: in U): U`, records a call site and builds as an interface call with the call's type arguments. Shape: `interface_generic_method` in `tir-builder-shapes-e2e.sh`.
