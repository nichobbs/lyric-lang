# D167 — `array[N, T]`: construction, surface and bounds checks

**Status:** accepted

Part of docs/67 phase G1 (#7940). Completes what `docs/01` §2.7 and D155
specify for `array[N, T]` (a fixed-length array with inline storage and
value semantics), which no target implements yet: dotnet and the JVM erase
it to an untyped object reference and native does not lower it.

## Decision

1. **Construction.**
   - A bracket literal where an `array[N, T]` is expected builds one:
     `val m: array[3, Int] = [1, 2, 3]`. The literal must have exactly `N`
     elements (**T0155** otherwise). This is the rule that already lets
     `[...]` build a `List[T]` where one is expected (binding initialiser,
     argument, field, return, `if`/`match` arm value).
   - A declaration without an initializer (`var a: array[16, Float]`, or a
     field of array type with no default) is filled with `T`'s zero value.
     A type has a zero when it is a scalar primitive (`0`, `0.0`, `false`,
     `'\u{0}'`), an enum (its first case), a distinct type whose underlying
     type has a zero and whose range, if any, contains it, a record whose
     fields all have zeros (or defaults), or an array of a type with a
     zero. A declaration without an initializer whose element type has no
     zero (a `String`, a union, a function, a range excluding zero) is
     **T0156**.
2. **Elements.** `T` may be any type. Copying an array copies its
   elements; an element that is a reference stays a reference to the same
   object (D157). `Plain` is required only where foreign layout matters
   (`buffer[T]`, `foreign record`).
3. **Value semantics.** Assigning, passing (`in`) or returning an array
   behaves as a copy. An element write `a[i] = v` (and `a[i] op= v`) needs a
   writable place: a `var` local, an `out`/`inout` parameter or a `var`
   field; anything else (including an element of a `List`) is **T0157**.
   The implementation keeps one invariant: every writable place exclusively
   owns its storage, and storage reachable from an immutable place is never
   mutated. So an array is copied when it is stored into a writable place
   (unless fresh) and when it is read from a writable place and the read
   escapes (including as an `in` or generic argument); a read of an
   immutable place is never copied. The copy is decided at the read or store
   site, where the type is concrete, so a generic callee needs nothing.
4. **Surface.**
   - `a[i]` reads element `i` (an integer index, or a range subtype of an
     integer type; a non-`Int` index is range checked as a `Long`).
   - `a.length` is `N`, a compile-time constant `Int`.
   - `for x in a` iterates the elements in index order, over the array's
     value when the loop starts.
   - `a.toSlice()` copies the elements into a new `slice[T]`. There is no
     implicit conversion between arrays, slices and lists.
   - `==` / `!=` compare element by element (D164's rules for each
     element); an array of functions has no `==` (T0153).
5. **Bounds.** An index outside `0 ..< N` panics with
   `index <i> out of range for array[<N>]`. When the index's type is a
   NAMED range subtype whose bounds lie within `0 ..= N - 1` (or is a literal
   in range), the access cannot fail and no check is emitted, on every target
   and in every build. An inline `Int range 0 ..= 3` annotation is not such a
   proof: it is not enforced on every path.
6. **Value-generic length.** `N` may be a value generic parameter
   (`generic[T, N: Nat] record FixedVec { data: array[N, T] }`,
   `func sum[N: Nat](a: in array[N, Int]): Int`). It is bound at each use by
   the length of the concrete array type and specialised by monomorphisation
   like a type parameter; `a.length` is the bound value.
7. **Representation.**
   - native: `[N x T]` inline when `T` is by-value (D-N, docs/67 §4.2), so
     an array of by-value elements is itself by-value and can sit inside a
     by-value record; otherwise a refcounted heap array (the `List`
     representation), copied when stored into a writable place.
   - dotnet and the JVM: the target's `List` (dotnet's `List<int>` and the
     like, which does not box numeric elements; the JVM's `ArrayList`, which
     does), copied per item 3, so writes through one binding are never seen
     through another. A `List` shares the index, assignment and iteration
     paths every backend already lowers, so the bounds check, the copy and
     the zero fill are one implementation for all three targets; a typed
     host array (`int[]`) removes the JVM's boxing without changing
     behaviour (#8041).

## Implementation

Shipped in `docs/progress/2026-10-02-fixed-arrays.md`: items 1 to 5 and 7.
Item 6 (value-generic `N`) is the next slice (#7940); the checker's `TyArray` already
carries `size: Option[Int]`, with `None` for a length it cannot fold (a value
generic parameter). Until item 6 lands, such an array is rejected where it
would need its length (**T0160**: index, `.length`, copy, `.copy`, `==`,
`for`), never accepted unchecked. A length that is neither a compile-time
constant nor a value generic parameter is T0160 where the type is written.

- **T0158** (an array index that is not an integer or a range subtype of
  one) is the diagnostic item 4's index rule needs. **T0159** (a record or
  union that holds an array in any field cannot derive `Equals`, `Hash`,
  `Show` or an ordering), **T0160** (an array that must be copied or indexed
  but has no known length or spelling, i.e. a value-generic `N`) and
  **T0113** (an array member other than `length` and `toSlice`, or `toSlice`
  referenced without being called) are the other diagnostics the
  implementation added, with **N0020** on `--target native` for an array type
  that reaches the backend with no native layout (an unresolved length or an
  element type with no native lowering; the checker rejects a non-constant
  length first).
- A field of a record, opaque type or protected type with no default is zero
  filled where its type is declared.
- Another package's record carries no such default, so a bracket
  literal or value for the field is required there (T0105, #8042).

## Consequences

- Derived `Equals`/`Hash`/`Show`/ordering on a type holding an array is T0159
  until derive synthesis calls the array equality lowering.
- `docs/01` §2.7 replaces the "not yet implemented" note with these rules;
  the book's collections chapter and appendix B (T0155–T0158) follow.
- docs/67 §4.3 is marked implemented as each slice lands.
- `buffer[T]` (docs/67 §4.4) builds on the same element and bounds rules.
