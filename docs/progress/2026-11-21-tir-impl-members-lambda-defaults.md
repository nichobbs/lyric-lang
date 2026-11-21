# TIR builder: generic impl member calls, lambda defaults, integer literals of a fixed type (D696)

A call of a member of a generic `impl` from another function, a lambda used as a default argument, and an integer literal passed where a generic parameter was fixed to `Byte`, `UInt` or `ULong` are built. Clears `generic_closure`, `impl_generic_target`, `inout_aliasing`, `lambda_gaps_batch` (defaults) and `inout_array_element` from the ilverify consumer list of #8613. Self-test: `tir_build_self_test.l`.
