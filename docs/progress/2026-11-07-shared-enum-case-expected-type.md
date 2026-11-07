# A shared enum case name is checked against its expected type (2026-11-07)

`val n: Int = Lib.On`, where `Lib` has two enums that both declare `On`, was accepted: the read is an
unresolved `TyError` (D355), a wildcard in `typeEquiv`, so an annotation of the wrong kind was never
compared against the enums that own the case (#8845). `inferExprExpected` now resolves such a read
against the expected type: an enum that owns the case picks its own case, and a primitive, or an enum,
record or union that does not own the case, is reported as a mismatch (T0060 on a `val`). Any other
expected type (an interface an enum implements, an unsolved variable) is left to the caller as before.
A local or module value of the same name is a value, not the case. Covered by `typechecker_self_test.l` cases.

Not covered here, tracked in a follow-up issue: a shared case passed as a call argument, which needs the parameter type of the overload actually selected (an overloaded `take(Beam)` / `take(Int)` must not turn a valid call into T0043), and calls through function values.
