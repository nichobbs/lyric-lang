# 2026-11-08 - TIR builder: function declarations and the I0003 census (D540)

docs/70 phase 3a, #8613. `Lyric.Tir.Build.buildFnDecl` assembles a `TFnDecl`
(modes, defaults, contracts as `preconds`/`postconds`) and records a `TSymEntry`
for each declaration a body reaches; `LYRIC_VERIFY_IR=1` now runs
`Lyric.Tir.Verify` over the built functions and reports I0003 per rule, plus the
first error of each body that does not build. The checker settles an annotated
initialiser's type so `val xs: List[Int] = newList()` no longer leaves `xs`
undeclared. Census over `collections_tests.l`: expression I0002 75 -> 58 of 568
before the instantiation read-back; `tir_build_self_test.l` has two new cases.
