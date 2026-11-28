# Methods and field defaults of an exposed record build as TIR members (docs/70 phase 3c, D880)

## What shipped

- `memberSites` and the field-default collection treat an `exposed record` as a `record` (D880, amends D512 "Not done"). A call of such a method no longer sends its caller to the AST path on native: a program calling `p.twice()` on an exposed `P` now lowers "2 of 2 functions from TIR".
- `tir_build_self_test.l`: a method of an exposed record builds and verifies.
