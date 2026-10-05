# One structural equality for operators, collections and payloads (#8003)

D172. Records that compare field by field, unions, tuples and arrays now
share one equality relation on every target. A `Float`/`Double` leaf is
equal when `==` holds or both are `NaN`. That relation is used by:

- `==`;
- union payload comparison;
- `==` through a type parameter;
- on dotnet and the JVM, a record or union as a `Map`/`Set` key or a
  `List.contains`/`indexOf` element.

## Before

Probing every case on dotnet and the JVM gave the same picture:

- `Map`/`Set` keys and `List.contains` compared a record by identity, even
  one deriving `Equals` and `Hash`;
- a union's record payload compared by identity;
- `same[T](a, b) = a == b` called with a value record compared by identity;
- a record field holding `NaN` was unequal to itself;
- union and tuple elements followed each host's boxed equality;
- tuples held `0.0` and `-0.0` unequal on all three targets.

## Shared pipeline

- **Float leaves.** The checker marks each `Float`/`Double` leaf of a
  record, array or shape site (`RecordEqSite.floatLeaves`, `AEFloat`,
  `ESFloat`). `lowerRecordEq` compares such a leaf over typed temporaries
  as `a == b or (a != a and b != b)`. The typed temporaries matter on the
  JVM, where a tuple element or union payload bound by a pattern is erased.
- **Tuples.** A tuple holding a `Float`/`Double` is compared by shape, as
  one holding an array already was.
- **Generic `==`.** `Lyric.Mono` reports each specialisation that binds a
  type parameter to a named type or a tuple (`MonoResult.structSpecs`). The
  pipeline re-checks those whose body uses `==`/`!=`, and lowers the record,
  array and shape comparisons the re-check records, as it already did for
  `UInt` and array specialisations.
- **Derived functions.** `Lyric.Derives` gives a derived `T.equals` the same
  float rule, and a derived `T.hash` hashes `f + 0.0` for a float field.

## dotnet

- **`buildStructuralEqualityOverridesMsil`.** Builds `Equals(object)` and
  `GetHashCode()` for every record that compares field by field, generic
  records included, and for every union case:
  - an integer, `Bool` or `Char` field uses `ceq`;
  - a `List`-represented field (a `List`, an `array[N, T]` or a tuple) loops
    over `IList` by its static element type;
  - every other field goes through
    `StructuralComparisons.StructuralEqualityComparer` (new MemberRefs).
- **`appendDeriveOverridesMsil`** reserves and emits both methods for such a
  record. A mutable record with `@derive(Hash)` alone keeps its delegating
  `GetHashCode`.

## JVM

- **Overrides.** `buildStructuralEqualsFunc`/`buildStructuralHashCodeFunc`
  replace the record builder that compared reference fields with
  `if_acmpeq`, and the union builder's `Objects.equals`.
- **Per-package helpers.** The overrides call four helpers, emitted when a
  package declares such a record or a union:
  - `__lyricKeyEq` and `__lyricKeyHash` dispatch on the runtime class:
    - a boxed `Double`/`Float`;
    - a `double[]`/`float[]` or an `ArrayList`, element by element;
    - another typed array, through `Arrays`;
    - anything else, through its own `equals`/`hashCode`.
  - `__lyricKeyEqD` and `__lyricKeyEqF` compare two scalars.

## Native

- `emitValueEqN` compares a `Float`/`Double` under the D172 rule. It backs
  union payloads, by-value records and inline arrays. A union holding a
  `NaN` now equals itself, matching dotnet and the JVM.
- A record that compares field by field but stays on the heap (one with a
  `String` field) was compared by pointer inside a union payload or array.
  It now goes through a synthesised `Record.eq` function (`ensureRecordEq`).
  `CodegenUnit.eqByFields` names such records.

## Verification

- New `structural_equality_self_test.l` (dotnet, JVM, native):
  - `NaN` and zero fields;
  - union payloads (`Option` included);
  - tuples and arrays;
  - generic `==` over value, derived and mutable records, unions and a bare
    `Double`.
- New `structural_equality_collections_self_test.l` (dotnet, JVM):
  - value, nested, generic, union and derived keys;
  - `NaN`, zero, array, nested-array and tuple fields;
  - a mutable record keeping identity;
  - `List.contains`, `indexOf` and a `Set`.
- `record_eq_self_test.l` and `llvm_inline_union_self_test.l` now assert
  D172's `NaN` rule.

## Follow-ups

- #8167: native `Map`/`Set` keys and `List.contains`/`indexOf` for
  structured values.
- #8169: `==` on `List` differs between dotnet (identity) and the JVM
  (element by element).
- #8170: a tuple used directly as a `Map`/`Set` key.
