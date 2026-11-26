# A default method of a generic interface runs on a generic implementor on dotnet (#9441, D862)

## What shipped

- dotnet: `impl[T] Holder[T] for Box[T]` with `Holder` declared in another package: `b.twice(9)` on a `Box[Int]` dispatched nowhere (`unsupported method` at run time). The generic-receiver arm of `lowerMethodCallMsil` now falls back to the interface slot of the impl, with the impl's interface arguments closed over the receiver's type arguments (`Holder[Int]` for `Box[Int]`, `Holder[String]` for `Box[String]`). The JVM already ran it.
- `default_method_cross_package_self_test.l`: a generic-implementor case on both targets.
