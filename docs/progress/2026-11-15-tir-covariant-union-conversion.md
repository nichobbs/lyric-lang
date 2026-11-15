# 2026-11-15 - TIR builder: covariant conversion of a union value (D487)

docs/70 phase 3a, #8613. `convertValue` rebuilds a union value used at other type arguments as a `match` over its cases with each payload converted (`retypeValue`), guarded against recursive unions. `tir-builder-shapes-e2e.sh` adds `covariant_union_values`. `covariant_conversion_self_test.l`: 24 of 28 bodies built; recursive unions, generic records and collections of them are the remainder.
