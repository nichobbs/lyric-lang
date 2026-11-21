# Iterating a value of a type parameter is T0230 (D682)

The checker rejected nothing for `for x in a` with `a: T` and left the loop variable untyped, which the typed IR cannot represent. It is now T0230 (the owner's decision): take `slice[T]` or `array[N, T]`. The reject corpus, two typechecker cases, docs/01 and the book's diagnostic table cover it; `fixed_array_self_test.l`'s `countGen` takes `array[N, T]`.
