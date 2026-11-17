# docs/70 phase 3a: a Long passed to a Nat-backed from (D498)

`Score.from(n)` with `n: Long` and a `Nat`-backed distinct or range type builds as a `CvLongToNat` conversion (non-negative check) before the wrap or range check, instead of being counted as an argument conversion (I0002).
