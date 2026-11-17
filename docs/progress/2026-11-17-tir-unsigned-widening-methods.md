# docs/70 phase 3a: the unsigned widening methods build as built-in calls (D451)

`toUInt()` and `toULong()` on a `Byte`, `UInt` or `ULong` receiver are recorded as built-in calls by the checker, so the generated plugin codec helpers and any program using them no longer count as "a call the checker did not resolve" (I0002).
