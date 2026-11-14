# 2026-11-14 - TIR builder: `d.value` of a distinct type and the Option/Result accessors (D463)

docs/70 phase 3a, #8613. `d.value` of a distinct type builds as `CvUnwrapDistinct`; `o.isSome`, `o.isNone`, `r.isOk` and `r.isErr` build as direct calls of the `Std.Core` functions, recorded by the checker under the member's node. `tir_build_self_test.l` adds the distinct case (188 pass).
