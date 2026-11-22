# Map.containsValue is a typed built-in member (D698)

The checker types `Map.containsValue` (value-typed parameter, `Bool` result) and records it as a built-in, so the TIR builder no longer counts it as a host call that fits no overload. `map_enhancements_self_test` builds all 25 bodies. Self-test: `tir_build_self_test.l`.
