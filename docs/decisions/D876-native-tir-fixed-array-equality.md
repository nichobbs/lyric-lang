# D876: the native TIR lowering takes `==` and `!=` on fixed arrays of scalars

Status: accepted (docs/70 phase 4a, part 9; D520 slice 53).

## Decision

`==` and `!=` on two `array[N, T]` values with a scalar element and `N <= 64` compare the elements one by one: an unrolled chain of `extractvalue` and the scalar comparison, ANDed (and negated for `!=`), as the AST path's derived equality does. Ordering operators, larger arrays and aggregate elements keep the AST path. `keptast.l` prints equal and unequal arrays and the e2e requires that no function falls back.
