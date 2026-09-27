# 2026-09-27 — Distinct values as Map and Set keys

D-progress-993, #7375.

Distinct and range-subtype wrapper classes on dotnet and the JVM now
override `Equals` / `GetHashCode` (`equals` / `hashCode`) by delegating to
the underlying value. A `Map` or `Set` keyed by a distinct type now finds a
key built separately from the one it was stored under. Native already
represented distinct values as scalars.

`distinct_ops_self_test.l` covers `Long`-, `Int`-, `Double`- and
`String`-backed keys on all three targets.
