# 2026-11-12 - TIR builder: assignment to an inout self (D588)

docs/70 phase 3a, #8613. `self = Ctr(n = x)` in a method with `self: inout Ctr` was counted as `an assignment target that is not a local, field or element` (22 self-test sites). The place builder now takes `self` as the receiver local (`PlLocal`), and counts `self` outside a method separately. `tir_build_self_test.l` adds a case (160 pass). The wide census was not re-measured.
