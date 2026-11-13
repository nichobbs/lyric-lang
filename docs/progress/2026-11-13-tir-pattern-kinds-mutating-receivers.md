# 2026-11-13 - TIR builder: or-patterns that bind, constant patterns, shorthand record fields, mutating receivers (D591)

docs/70 phase 3a, #8613. Or-pattern alternatives share the first alternative's locals; `@NAME` builds as `TpConst` from the symbol the checker now records; `P { x, y }` binds field-typed locals; a method with an `inout`/`out` receiver takes it as a place argument. `tir_build_self_test.l` adds four cases and updates three (176 pass).
