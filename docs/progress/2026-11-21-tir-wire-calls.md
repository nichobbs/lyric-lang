# TIR builder: calls through a wire's factory (D684)

`W.bootstrap(provided...)` and `W.binding()` on a `wire` block build as the new typed-IR intrinsic `IoWire(wire, member)`, typed from the wire's declaration (`Unit`, or the exposed binding's declared type), with interface codec and dump support and an explicit "unsupported" in the ported native lowering. Clears `examples/agent/di-and-async.l` and the wire-using bodies of #8613's phase 3a list. Self-test: `tir_build_self_test.l`.
