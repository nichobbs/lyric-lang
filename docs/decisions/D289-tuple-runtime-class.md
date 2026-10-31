# D289 — A tuple has a runtime class with structural equality

**Status:** accepted

Closes the tuple-key item of D172 (#8170).

## Context

D172 gave records and union cases structural `Equals`/`GetHashCode` (dotnet) and
`equals`/`hashCode` (JVM), so they work as `Map`/`Set` keys. A tuple stayed a
bare host list: `List<object>` on dotnet, `ArrayList` on the JVM.

- **dotnet.** `List<object>` has no `Equals`/`GetHashCode` override, so
  `m.containsKey((1, 2))` missed a key added as `(1, 2)`.
- **JVM.** `ArrayList.equals` compares a `Double` element with
  `Double.equals`, so `(1, 0.0)` and `(1, -0.0)` were two keys, against D172.

Passing an `IEqualityComparer` to `newMap`/`newSet` was ruled out: generic
stdlib code (`setUnion`, `setFromSlice`, `mapEntries`, ...) builds maps and
sets without knowing the key type, so the equality has to travel with the
tuple object.

## Decision

1. **A tuple is an instance of a synthesised class.** The class extends the
   host list and overrides equality and hash:
   - dotnet: `Lyric.Internal.LyricTuple : List<object>`, the first TypeDef of
     every assembly, with `Equals(object)` and `GetHashCode()`.
   - JVM: `<package>/__LyricTuple extends ArrayList`, one per package that
     builds a tuple, with `equals(Object)` and `hashCode()`.
2. **The relation is D172's.** Elements are compared in order.
   - A nested list, tuple or array element is compared element by element.
   - A boxed `Double`/`Float` is equal when `==` holds or both are `NaN`, so
     `0.0` equals `-0.0`; the hash agrees.
   - A record or union element uses its own override, a `String` its text.
   - A `Set` or `Map` element keeps the host's equality.
3. **Equality tests the interface, not the class.** dotnet `Equals` accepts any
   `IList` and the JVM helper any `ArrayList`, so tuples built by different
   assemblies or packages, or a tuple against a plain list of equal elements,
   compare equal. Two assemblies each carry their own class.
4. **Construction sites.** The two tuple construction sites switch to the
   class (`ETuple` and its hole-collecting twin on dotnet; `ETuple` on the
   JVM). Reads (`castclass`, pattern binding, `IList` access) are unchanged,
   since the class is a subtype of what they already use.
5. **dotnet layout.** The class occupies TypeDef row 1 and MethodDef rows 1 to
   7 (`.ctor`, `Equals`, `GetHashCode`, and four instance helpers), so the
   code generator starts every package's predicted MethodDef rows after them.
6. **JVM helpers.** `equals`/`hashCode` call the package's `__lyricKeyEq` and
   `__lyricKeyHash` (D172), which compare an `ArrayList` element by element and
   so do not re-enter the class's own `equals`.
7. **Native** keeps **N0007** for a tuple key.

## Consequences

- A bare tuple is a `Map` key and `Set` member on dotnet and the JVM, and
  `List.contains` on a list of tuples uses the same relation.
- Every dotnet assembly grows by one small class.
- `List.indexOf`/`remove` on a list whose element type is a tuple still
  misbehave on dotnet (they miss even the identical reference); that predates
  this decision and is tracked in #8668.
