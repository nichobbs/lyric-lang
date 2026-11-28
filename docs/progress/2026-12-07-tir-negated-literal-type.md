# A negated unsuffixed literal takes the negation's type on TIR (docs/70 phase 3c, D881)

## What shipped

- The builder's `EPrefix` arm gives a numeric literal operand the type of the negation it sits under (`val n: Float = -0.1` is a `Float` negation of a `Float` literal), removing a native fallback found by the native-via-TIR census (D881).
- `tir_build_self_test.l`: the negation's operand and result types agree and the body verifies.
