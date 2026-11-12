# 2026-11-12 - TIR builder: a try that ends a block yields its value through a local (D586)

docs/70 phase 3a, #8613. `try { ...; 42 } finally { ... }` as the value of a block was counted as a `Unit` to `Int` branch conversion because `try` is a statement in TIR. The builder now declares a `var` before the `TsTry`, assigns the body's and each catch's tail to it and takes the local as the block's value (no `XTry`); a tail that never completes stays a statement. `tir_build_self_test.l` adds a case with `finally`, `catch` and a panicking body (157 pass). The wide census was not re-measured.
