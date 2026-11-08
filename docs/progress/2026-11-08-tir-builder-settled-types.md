# 2026-11-08 - TIR builder: settled types, property reads, generic cases (D541)

docs/70 phase 3a, #8613. A closed expected type settles an expression the checker
typed with a hole; a call argument takes its parameter's type; collection `count` and
string/slice/array `length` are built-in property reads; generic union cases construct
at their closed instantiation; `f[A, B](x)` records its callee by node. The stdlib test
census: `collections_tests.l` 13/13 bodies built, `json_value_tests.l` 12/12,
`string_tests.l` 12/13, `core_tests.l` 5/10, I0003 0 throughout. `tir_build_self_test.l`
has 91 cases.
