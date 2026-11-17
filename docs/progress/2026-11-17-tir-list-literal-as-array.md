# docs/70 phase 3a: a list literal typed as a slice used as a fixed array (D495)

`convertValue` retypes a slice-typed list literal of exactly the array's length as an array literal, converting each element (`retypeListLiteral`). Removes the `slice[T]` to `array[N, T]` share of the "argument conversion" I0002 kind (about five self-test sites in the wide census of 2026-11-17).
