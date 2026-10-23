# 2026-10-23 - `inout`/`out` parameter batch

Group `inout-out-params`. Decision: D205.

- #8255: a default on an `out`/`inout` parameter is T0182 on every target.
- #8318, #8229: an `out`/`inout` parameter on an `async` function is T0183 on
  every target (it was a silently lost write on dotnet).
- #8369: a function with an `out`/`inout` parameter used as a value is T0128
  (it was T0115 on dotnet, J008 on the JVM).
- #8215: a non-`var` field as an `inout` receiver (`h.p.reset()`) is T0166; the
  argument form was already T0085.
- #8272: the JVM narrows an erased receiver before building a by-reference
  field place.
- #8368: a woven function with an `inout` parameter, regression test on both
  targets.

Each rule has `typechecker_self_test.l` cases (free function, record method,
dot-named function, interface member). docs/01 §5.2, docs/09 §11.4 and book
appendix B are updated; the stale `A0001` warning row is gone.
