# 2026-11-14 - TIR builder: source-loaded bare-case and suffixed-integer defaults (D485)

docs/70 phase 3a, #8613. A default the standard library declares as `None`, an enum case or a suffixed integer literal builds from the parameter's type, without an interface (`nullaryCaseOf` in `build_syms.l`, `buildForeignCaseDefault` in `build_expr.l`). `tir-builder-shapes-e2e.sh` adds `stdlib_case_defaults`. Stdlib-tests census: "default argument declared in another package" 22 -> 6 before the suffix rule.
