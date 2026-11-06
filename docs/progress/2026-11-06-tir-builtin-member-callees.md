# 2026-11-06 - Primitive members, numeric conversions and dependency union cases record their callee (D363)

The census over the stdlib tests now lists only function-value calls and method
calls on interface and extern receivers. `recordBuiltinCall` takes the member's
type and records any function-typed member of a primitive, slice or array
receiver; numeric conversions record at their early return; a dependency's union
case is keyed `package::Union::Case`; the expected-type case construction
records its callee. `tir_build_self_test.l` has a numeric-conversion and
string-member case (13 cases).
