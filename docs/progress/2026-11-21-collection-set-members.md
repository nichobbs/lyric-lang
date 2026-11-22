# Checker: `List.set` and `Map.set` are typed Unit members (D694)

`xs.set(i, v)` and `m.set(k, v)` are `Unit` with checked parameters and are built as built-in calls. Self-test: `llvm_stdlib_self_test.l` (native).
