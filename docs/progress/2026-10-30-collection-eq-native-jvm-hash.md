# Native `List` equality and JVM `Set`/`Map` hashing under D172 (#8439, part of #8167)

`--target native` lowered `==` and `!=` on two `List` values to a pointer compare,
so two equal lists were unequal (and `[0.0] == [-0.0]` was false). `==` on a
`List` is now a synthesised element-wise function (`__list.eq.<elem>`): equal
lengths, then each element pair under `emitValueEqN`, so a `Double`/`Float`
element follows D172 and a `String`, record, union or nested list element
compares structurally. `emitValueEqN` has the same arm, so a record field of
list type compares by contents too. Covered by
`llvm_collections_self_test.l` (ASan) and, on every target,
`record_eq_self_test.l`.

On the JVM, `__lyricKeyHash` had no `HashSet`/`HashMap` arm and fell through to
`Object.hashCode`, which hashes `0.0` and `-0.0` apart. A record holding a
`Set[Double]` could therefore compare equal (via `__lyricKeyEq`) and hash
differently. The helper now folds a set's members and a map's entries
order-independently through `__lyricKeyHash`. Covered by a JVM-only case in
`hash_jvm_self_test.l` (dotnet's `HashSet.GetHashCode` is by reference, so a
`Set`-holding record key does not work there; a separate gap).

Not done: native `==` on `Map`/`Set` (native has no `Set`).
