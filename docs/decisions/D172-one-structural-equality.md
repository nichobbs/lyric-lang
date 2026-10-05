# D172 — One structural equality for operators, collections and payloads

**Status:** accepted

Supersedes the `Float`/`Double` clause of D164 item 1, and closes D164
item 6 (#8003).

## Context

D164 made `==` on a value record compare field by field on every backend,
by lowering the operator in the shared pipeline. Equality that a backend
runtime performs on its own did not change:

- **Host collections.** `Map`/`Set` keys and `List.contains`/`indexOf` call
  the host's `Equals`/`GetHashCode` (dotnet) or `equals`/`hashCode` (JVM).
  On both, a record class compares by identity, so `m.containsKey(P(x = 1))`
  misses a key built separately. That includes a record that derives
  `Equals` and `Hash`.
- **Union payloads.** Union equality compares payload fields with the
  host's equality, so `U.A(v = p1) == U.A(v = p2)` is false on dotnet and
  the JVM for equal but separately built records, and true on native.
- **Generic code.** `func same[T](a: in T, b: in T): Bool = a == b` called
  with a value record compares identity on dotnet and the JVM. The
  checker records D164's sites before `Lyric.Mono` binds `T`.
- **`NaN` and `-0.0`.** Record fields follow IEEE (`NaN` is never equal).
  Union payloads and tuples follow each host's boxed equality: `NaN` equal
  to itself, and `0.0`/`-0.0` equal or not depending on the target and the
  shape.
- **Arrays.** A record with an `array[N, T]` field hashes and compares the
  array by identity in a host collection.

A host hash collection needs an equivalence relation: a key must equal
itself, or it cannot be found again. IEEE `==` is not one, since `NaN`
differs from itself.

## Decision

1. **Structural equality.** Every value compared by structure, rather than
   by identity, uses one relation:
   - records that compare field by field (D164 items 1 and 2);
   - unions;
   - tuples;
   - `array[N, T]`;
   - distinct types over any of these.

   Two such values are equal when their leaves are equal:
   - a `Float` or `Double` leaf is equal when IEEE `==` holds or both are
     `NaN`. So `0.0` equals `-0.0`, and `NaN` equals `NaN`;
   - every other leaf follows D164: text for `String`, identity for a
     mutable record, the underlying value for a distinct type, and its own
     type's `==` otherwise.

   `==` on a bare `Float`/`Double` stays IEEE. The relation differs from it
   only in that `NaN` is equal to itself, which makes `x == x` true for any
   structured value.

2. **One relation everywhere.** These all use this relation, on every
   target:
   - the operators `==`/`!=` on these values;
   - a record or union as a host collection key or element (`Map`, `Set`,
     `List.contains`, `List.indexOf`);
   - union payload comparison;
   - the derived `T.equals` of `@derive(Equals)`.

   A bare tuple as a collection key is #8170.

3. **Host overrides.** On dotnet and the JVM, every record that compares
   field by field gets an `Equals(object)`/`GetHashCode()` override
   (`equals(Object)`/`hashCode()` on the JVM). Each override implements the
   relation, including generic records. Union case classes get the same
   field rules. The hash is consistent with the relation:
   - `0.0` and `-0.0` hash alike, and so do all `NaN`s;
   - an array hashes element by element;
   - a nested record hashes through its own override.

   `@derive(Hash)` keeps its user-visible `T.hash`. A mutable record that
   does not derive `Equals` keeps identity for both its equality and its
   hash.

   On both hosts an `array[N, T]` field and a tuple field share their
   representation with `List` (`List<T>`/`List<object>` on dotnet,
   `ArrayList` on the JVM). So the overrides compare every such field
   element by element, a `List` field included. What `==` means on a
   `List` itself, which differs between the two targets today, is #8169.
   A tuple used directly as a `Map`/`Set` key, rather than inside a record or
   union, is #8170.

4. **Generic `==`.** A `==` in a generic body that `Lyric.Mono`
   specialises to a type compared by structure compares as that type's
   `==`.
   - For a generic declared in the same package, the specialisation is
     checked again, as one binding `UInt` or an array type already is, and
     the comparison is lowered.
   - A generic from another package is checked in that package's scope,
     where the consumer's type is not visible. So its `==` reaches the
     bound type's own structural equality from item 3 on dotnet and the
     JVM, and native's structural comparison.

5. **Native collections.** `--target native` keeps **N0007** for a `Map`
   or `Set` key that is not a `String` or a scalar. `List.contains` and
   `List.indexOf` are not yet lowered there for any element type. Native
   union and tuple equality follow item 1. Record keys and those two
   methods are tracked as a native follow-up (#8167), which must use this
   relation.

## Implementation

- **Shared pipeline.** The checker marks each `Float`/`Double` leaf of a
  record, array or shape site (`RecordEqSite.floatLeaves`, `AEFloat`,
  `ESFloat`). `lowerRecordEq` compares such a leaf as
  `a == b or (a != a and b != b)`, over typed temporaries.
  - A tuple holding a `Float`/`Double` is compared by shape
    (`isEqWrapperType`), as one holding an array already was.
  - Mono reports each specialisation that binds a type parameter to a named
    type or a tuple. The pipeline re-checks those whose body uses `==`/`!=`
    and lowers the comparisons the re-check records.
- **dotnet.** `buildStructuralEqualityOverridesMsil` builds both overrides
  for records and union cases:
  - integer fields use `ceq`;
  - `List`-represented fields loop over `IList` by their static element
    type;
  - every other field goes through
    `StructuralComparisons.StructuralEqualityComparer`.
- **JVM.** `buildStructuralEqualsFunc`/`buildStructuralHashCodeFunc` call
  four per-package helpers: `__lyricKeyEq`, `__lyricKeyHash`,
  `__lyricKeyEqD` and `__lyricKeyEqF`.
- **Native.** `emitValueEqN` compares a `Float`/`Double` under item 1. It
  backs union payloads, by-value records and inline arrays. A heap record
  that compares field by field (one holding a `String`, say) goes through a
  synthesised `Record.eq` function rather than its pointer.
- **Derived functions.** `Lyric.Derives` gives a derived `T.equals` the same
  float rule, and a derived `T.hash` adds `0.0` to a float field first.

## Rationale

- Item 1 makes the relation reflexive, which a hash table needs. It also
  agrees with scalar `==` for every non-`NaN` value, so a record's `==` is
  still "its fields are `==`" in every case a program can reasonably test.
- Choosing `0.0 == -0.0` follows scalar `==` and dotnet's `Double.Equals`.
  Treating them as different (the JVM's `Double.equals`) would make
  `P(x = 0.0) == P(x = -0.0)` disagree with `0.0 == -0.0`.
- Overrides on the host classes, rather than comparer objects passed to
  each collection, keep `Std.Collections` a thin layer over the host
  collections. They also make the relation hold when a value crosses into
  host code.

## Consequences

- `docs/01` §2.4 (records) and §2.5 (unions) state the relation and the
  `NaN` rule. The book's records chapter follows.
- A record field holding `NaN` now compares equal to itself under `==`.
  D164's "NaN is never equal" for record fields no longer holds.
- Tuples compare `0.0` and `-0.0` as equal on every target. Before, they
  compared unequal.
