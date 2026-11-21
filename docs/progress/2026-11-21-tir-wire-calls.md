# TIR builder: calls through a wire's factory (D684)

`W.bootstrap(provided...)` and `W.binding()` on a `wire` block are typed by the checker (`Unit`, or the exposed binding's declared type) and build as the new typed-IR intrinsic `IoWire(owner, member)`, with interface codec and dump support and an explicit "unsupported" in the ported native lowering. Clears `examples/agent/di-and-async.l` and the wire-using bodies of #8613's phase 3a list. Self-test: `tir_build_self_test.l`.
