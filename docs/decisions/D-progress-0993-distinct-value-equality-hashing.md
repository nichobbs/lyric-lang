# D-progress-993 — Distinct wrapper classes have value equality and hashing

**Status:** shipped

Closes #7375. Follows D-progress-992.

## Problem

On dotnet and the JVM a distinct value is a wrapper class around its
underlying value. D-progress-992 made `==` compare underlying values, but
it only rewrites operators the type checker sees. A `Map` or `Set` hashes
and compares its keys through the runtime's own `Equals` / `GetHashCode`
(dotnet) or `equals` / `hashCode` (JVM). The wrapper classes did not
override either, so a key built separately from the one stored under was
never found:

```lyric
type UserId = Long
val byUser: Map[UserId, String] = newMap()
byUser.add(UserId.from(7i64), "seven")
byUser.containsKey(UserId.from(7i64))   // false on dotnet and the JVM
```

Native represents a distinct value as its underlying scalar, so it already
worked there.

## Decision

Every distinct and range-subtype wrapper class gets value-based overrides
that delegate to the underlying value:

- **dotnet** (`Msil.Lowering.lowerMDistinctType`, methods 4 and 5):
  `Equals(object)` returns false unless the argument is the same wrapper
  type, then calls `Object.Equals(object, object)` on the two boxed
  underlying values. `GetHashCode()` calls `GetHashCode` on the boxed
  underlying value. An unsigned underlying type boxes as `UInt32` /
  `UInt64`. The pass-1 token budget reserves the two extra MethodDef rows.
- **JVM** (`Jvm.Lowering.lowerDistinctType`): `equals(Object)` checks
  `instanceof` and then calls `Objects.equals` on the two boxed values.
  `hashCode()` calls `Objects.hashCode` on the boxed value.

Delegating to the boxed value's own equality keeps `Double` NaN keys
reflexive, as a hash key must be. That differs from the `==` operator on
`Double`, which follows IEEE 754; the operator is unchanged. The hash is
always consistent with the collection equality.

Equality is by type as well as value: two distinct types over the same
underlying type never compare equal as keys, matching the type checker,
which rejects `==` between them.

## Tests

- `distinct_ops_self_test.l` adds a `Map`-key case for `Long`-, `Int`-,
  `Double`- and `String`-backed distinct types, and `==` inside a generic
  function instantiated with a distinct type. It runs on dotnet, JVM and
  native.
- `distinct_collections_self_test.l` covers `List.contains` on dotnet and
  the JVM. Native `List.contains` on a non-`String` element fails codegen
  (#7429).
- `lyric-stdlib/tests/set_tests.l` covers `Set` membership and
  de-duplication of distinct values. `Std.Set` does not run on the JVM
  (#7312).

## Docs

The language reference §2.3 no longer lists the identity-hashing caveat.
