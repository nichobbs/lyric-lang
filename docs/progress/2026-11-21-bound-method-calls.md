# Checker: a method call on a bounded type parameter (D686)

`x.say(1)` where `x: T` and `where T: Speaker` is typed and its callee and call site recorded as the bound interface's member, so the typed-IR builder builds it as an interface call. Self-test: `tir_build_self_test.l`.
