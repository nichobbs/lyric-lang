# D175 — Value generic parameters on unions and opaque types

**Status:** accepted

Settles the union and opaque-type half of D169's follow-up (#8149). Protected
types keep **T0160**: their per-length layout on native needs generic
protected types there (#7864).

## Context

D169 lets a record's value generic parameter size its array fields, and D173
makes such a record usable from any package: one erased class on dotnet and
the JVM, one specialisation per length on native. A union's, opaque type's
or protected type's value parameter was **T0160** where it sized an array.

An opaque type is a record whose fields are private to its package, so the
record design applies unchanged. A union differs in one way that matters on
native: its cases are constructed and matched by name, not through the type.
Specialising `Shape[N]` per length gives `Shape__V3` and `Shape__V5`, both
with a case `Poly`, so a bare `Poly(...)` no longer says which one it builds.

## Decision

1. **An opaque type and a union may take value generic parameters that size
   their array fields**, with the rules of D169 and D173: an instance is
   written `Shape[3]` or `Tagged[T, 3]`, a construction binds each length
   from an array argument or the expected type, instances of different
   lengths are different types (T0060, or T0043 for an argument), and the
   type may be used from any package.
2. **One runtime type on dotnet and the JVM.** The value parameters are
   erased, as a record's are (D173 item 2). An opaque type or union whose
   only generic parameters are values is one non-generic class.
3. **One type per length on native, case names kept.** A union is
   specialised per length like a record (`Shape__V3`), and each
   specialisation keeps the case names. The type checker records each
   construction of a case, and each reference to a case with no fields, with
   the union and the lengths it is typed at, the expected type's when the
   construction leaves a length open (`val e: Shape[3] = Empty`). Before
   monomorphisation the middle end spells each such site with its union and
   lengths, and after it names the specialisation's case
   (`Shape__V3.Poly(...)`). A pattern resolves a case by its scrutinee's
   type, so a qualified pattern (`case Shape.Poly(p)`) drops its union name.
4. **The middle end treats both as records.** An opaque type's fields, and a
   union's case fields in order, are the fields of a record view that the
   existing specialisation and erasure passes rewrite; the result is put back
   as the opaque type or union it was. An opaque type keeps its private
   fields: its methods are value-generic functions declared in its package
   (`func Window.total[N: Nat](self: in Window[N]): Int`).

## Rationale

- Reusing the record passes keeps one implementation of length binding,
  specialisation across packages (D173 item 3) and contract metadata as
  written.
- Specialising a union in codegen instead, with each length as a type
  argument of a generic union, would need native to infer a length from
  every construction, which it cannot do when the array is a heap list
  (an element that is not by value), and could not reach a record instance
  in a case field (`inner: Ints[N]`), which only the middle end specialises.
- Duplicate case names across unions are already legal and resolved by the
  scrutinee's type in a pattern and by qualification in a construction on
  every backend, so qualifying constructions is enough.

## Consequences

- T0160 for a field array length is now raised for a protected type only.
- Native generic union construction binds a type parameter from any field
  type that mentions it (`items: array[2, T]`), as a generic call's
  arguments do, not only from a field typed as the bare parameter.
- On the JVM each package of a bundle learns which classes of the other
  packages are opaque, so a specialisation of another package's generic
  function reads an opaque field through its accessor.
