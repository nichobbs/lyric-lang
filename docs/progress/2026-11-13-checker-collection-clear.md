# 2026-11-13 - Checker: a collection's clear() is a built-in member (D461)

`xs.clear()` on a stdlib `List`, `Map` or `Set` is recorded as the built-in `List.clear` / `Map.clear` / `Set.clear`, so the
TIR builder builds it as a built-in call instead of failing to find a host method named `clear` (the host's is `Clear`).
Test: `typechecker_self_test.l`.
