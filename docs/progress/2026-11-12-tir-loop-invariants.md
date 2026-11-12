# 2026-11-12 - TIR builder: loop invariants (D589)

docs/70 phase 3a, #8613. A loop's `invariant:` clause (the statement `SInvariant`) was counted as `a loop invariant` (19 self-test sites). It now builds as `TsInvariant` over the clause's expression; the verifier checks it is a `Bool`. `tir_build_self_test.l` adds a case (166 pass). The wide census was not re-measured.
