# TIR builder: a discarded call on a generic host class (D683)

A call statement on a generic host class applied to concrete arguments (`d.put("a", "1")` on a `ConcurrentHashMap[String, String]`), and a `Unit` function that ends in one, now build: the node settles at the host's root `Object`, which is all a discarded value needs (`settleDiscardedHostCall`, `build_expr.l`). A used value is unchanged. Closes the `makeDict` bodies of #8613's phase 3a list. Self-test: `tir_build_self_test.l`.
