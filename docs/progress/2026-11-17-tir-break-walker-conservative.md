# 2026-11-17: the never-ending-loop check also looks through initializers (D440)

`blockMayBreak` now descends into `unsafe` blocks, assignment values, `val`/`var` initializers and `return` values, so a loop that can `break` from inside one of them is no longer taken to never complete. The "loop with a break stays counted" self-test asserts the specific I0002 instead of a near-vacuous disjunction, and a new case covers a `break` inside a `val` initializer. Follow-up to the review of #9182.
