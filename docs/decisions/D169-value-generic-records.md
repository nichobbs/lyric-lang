# D169 — Value-generic records: a record's `N: Nat` sizes its array fields (#8090)

**Status:** shipped

Completes D167 item 6 for records. Functions already take a value generic
parameter that sizes an array (`func total[N: Nat](a: in array[N, Int])`,
`docs/progress/2026-10-03-value-generic-array-lengths.md`). A record cannot:

```lyric
record FixedVec[T, N: Nat] {
  var data: array[N, T]
}
```

is **T0160** where it is declared. This entry settles how it works.

## Decision

1. **Declaration.** A record or exposed record may declare value generic
   parameters (`N: Nat`) beside its type parameters, in any order. A value
   parameter may size an array field (`array[N, T]`, nested arrays, an array
   inside a tuple or a generic argument) and may be used as a value in the
   record's methods and invariants, where it is the instance's length.
   Unions, opaque types and protected types keep **T0160** for now; their
   value parameters are a follow-up (#8149).

2. **The type.** `FixedVec[Int, 3]` names an instance. Each argument must
   be of its parameter's kind:
   - a value parameter takes an integer literal, a module-level constant,
     or a value parameter of the enclosing function or record;
   - a type parameter takes a type.

   An argument of the wrong kind is **T0163**. That replaces T0109 for a
   value argument written for a type parameter of a type that has value
   parameters. Two instances with different lengths are different types, as
   `array[3, Int]` and `array[4, Int]` are.

   In the checker an instance is a `TyUser` whose arguments line up with the
   parameters. A value parameter's argument is a new `TyLen(n)` when it is
   known, or the `TyVar` of an enclosing value parameter in a generic body.
   A field's type at an instance is the field's declared `TypeExpr` with the
   arguments substituted, then resolved, so `data` of a
   `FixedVec[Int, 3]` is `array[3, Int]`.

3. **Construction.** A value parameter is bound the same way a type
   parameter is, and with the same functions use:
   - from an array field argument's length (`FixedVec(data = a)` with
     `a: array[3, Int]` is a `FixedVec[Int, 3]`);
   - or from the expected type (`val z: FixedVec[Int, 3] = FixedVec()`,
     which zero fills `data`).

   A constructor takes no explicit type arguments, for value parameters as
   for type parameters.

   Two field arguments that disagree are **T0043**. A parameter nothing
   binds is **T0110**.

4. **Bodies.** A method of such a record is checked once with its value
   parameters symbolic, like a value-generic function body: the length
   checks that need `N` are deferred. It is checked again for each instance
   the program uses.

5. **Lowering: specialise per length, on every target.** `Lyric.Mono`
   specialises each instance's value arguments away.
   - `FixedVec[Int, 3]` and `FixedVec[String, 3]` both become a
     `FixedVec__V3[T]` record whose field is `array[3, T]`, declared once
     in the file. Its methods are copied with `N` replaced by `3`.
   - Every type reference, constructor call and method call is rewritten to
     it.
   - The result is an ordinary type-generic record, which every backend
     already lowers: reified on dotnet, erased on the JVM, and instantiated
     per type argument on native.
   - A length cannot be a CLR or JVM type parameter. Specialising rather
     than erasing `N` also keeps `.length`, bounds checks, zero fill and
     copies as constants in method bodies, as they are in a value-generic
     function's specialisation.
   - Each specialised record is checked again, with errors as **M0007** in
     the pipeline. A function generic over an instance
     (`func sum[N: Nat](v: in FixedVec[Int, N])`) is specialised first, and
     then the records it names.

6. **Package-local in this slice** (SUPERSEDED by D173, which removes T0164
   and changes item 5 on dotnet and the JVM). A value-generic record may be used only
   in the package that declares it. A use from another package, through an
   import or a restored dependency, is **T0164**.

   Specialising in each consumer would give two packages two distinct
   `FixedVec__V3` types for one Lyric type. A runtime type is nominal per
   assembly on dotnet, and per class on the JVM. The cross-package design
   (specialisations owned by the declaring package's metadata, or a shared
   naming scheme the loader unifies) is a tracked follow-up (#8150). The record
   may be `pub`; only a use outside its package is refused.

## Implementation

Shipped in `docs/progress/2026-10-04-value-generic-records.md`. The checker
types an instance as a `TyUser` with `TyLen` arguments; `TyArray` carries the
name of a length that is a value parameter (`sizeVar`), which substitution
fills. The middle end marks each construction with its lengths before
`Lyric.Mono` (`markValueRecordCtors`), specialises the records after it
(`specialiseValueRecords`, renaming through `Lyric.TypeAliasResolve`
markers), and re-checks each specialisation's methods to lower their array
operations (`lowerValueRecordSpecs`). Two fields giving one parameter
different lengths is T0043, as item 3 says.

## Rationale

- Specialisation reuses machinery that already ships:
  - the checker's length binding (`bindArrayLengths`);
  - `Lyric.Mono`'s value substitution (`substTypeArg`, `substValueInBody`);
  - the per-specialisation re-check (`recheckSpecs`);
  - each backend's generic-record path.
- Keeping the type parameters generic in the specialised record avoids
  multiplying record copies by element type on dotnet and the JVM.
- A `TyLen` argument rather than a length inside `TyArray` keeps every
  existing `TyArray` consumer unchanged. Field types are computed from the
  declaring `TypeExpr`, where the parameter name is still known.

## Consequences

- `docs/01` §2.7 (arrays) and §4 (generics) document value parameters on
  records, `TyLen`-style instance types, T0163 and T0164.
- Book chapter 3 shows a value-generic record. Appendix B lists T0163 and
  T0164.
- Follow-ups are tracked:
  - value parameters on unions, opaque and protected types (#8149);
  - cross-package value-generic records (#8150).
