# D531: protected-type field initializers lower from TIR on native

Status: accepted (docs/70 phase 4a, part 5; D520 slice 32).

## Finding

The coordinator listed protected-type field initializers as staying on the AST path. Measured on the current main they do not: `Box()` and `Gauge()` constructions lower from TIR (`constructProtected`, D520 slice 27) with initializers that are literals, a call (`seed() + 2`), a record construction, an enum case, a string concatenation, `newMap()`, `newList()` and an array literal. The checker materialises each field's initializer into the construction's field list, so the lowering needs no further work.

The one initializer that still falls back is a generic union (`var opt: Option[Int] = None`): the case symbol is not a registered record because generic unions wait for 3c (monomorphised TIR). That is the existing generic-union limit, not a protected-type one.

## Decision

No lowering change. The coverage is pinned: `scripts/ci/native-via-tir/protected.l` gains a `Gauge` protected type with the initializer shapes above, and `native-via-tir-e2e.sh` requires every function of the fixture (7 of 7) to lower from TIR, output equal to the AST path, and an AddressSanitizer run (the `String`, `Map` and array initializers exercise the destructor of a heap field).
