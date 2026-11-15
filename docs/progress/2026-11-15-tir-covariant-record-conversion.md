# 2026-11-15 - TIR builder: covariant conversion of a generic record value (D488)

docs/70 phase 3a, #8613. `retypeValue` rebuilds a generic record used at other type arguments (`Box[English]` as `Box[Greeter]`) as a bound local and a construction with each field read and converted; a record with a `var` field stays counted. `tir-builder-shapes-e2e.sh` adds `covariant_record_values` and `covariant_recursive_union_stays_counted` (a regression test for D487's recursion guard).
