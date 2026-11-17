# 2026-11-17: protected-type field initializers pinned as TIR-lowered (D531)

Protected-type field initializers (a call, a record, an enum case, a string, `newMap()`, an array literal) already lower from TIR; the only fallback is a generic-union initializer such as `Option[Int] = None`, which waits for 3c. `protected.l` now carries a `Gauge` type with those initializers, required to lower fully from TIR and run clean under AddressSanitizer. See D531.
