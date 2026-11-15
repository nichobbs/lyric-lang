# 2026-11-14 - TIR builder: a method call names its own declaration (D484, #9106)

`recordMethodCalleeNode` tries the declaration at the signature's span (a dot-named function, then a method) before the
same-arity fallback for a dependency's dot-named function, so a record method beside `func R.m` of another arity is called as
itself. Test: `method_beside_dot_named` in `scripts/ci/tir-builder-shapes-e2e.sh`.
