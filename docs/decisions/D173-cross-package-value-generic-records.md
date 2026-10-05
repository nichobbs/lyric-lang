# D173 — Value-generic records across packages

**Status:** accepted

Supersedes D169 item 6 (T0164) and changes D169 item 5 on dotnet and the
JVM (#8150).

## Context

D169 specialises a value-generic record per length inside the package that
uses it. `FixedVec[Int, 3]` becomes a record `FixedVec__V3[T]` in that file,
and its methods are copied with `N` replaced by `3`.

Done in every consumer, this gives two packages two runtime types for one
Lyric type. A value passed between them would fail to cast, because types
are nominal per assembly on dotnet and per class on the JVM. So a use from
another package was **T0164**.

Two facts make a cheaper design possible:

1. **Nothing in the class depends on `N` on dotnet or the JVM.** An
   `array[N, T]` field is a `List<T>`, an `ArrayList` or a typed Java
   array there, and none of those types carries a length. Zero fill
   happens at the construction site, and copies at the read or store site.
   `N` appears only in method bodies (`.length`, bounds checks, fills,
   copies).
2. **Value-generic functions already cross packages.** `Lyric.Mono`
   specialises them per length in each consumer, from the body the
   declaring package exports (D167), and generic functions named after a
   record specialise like any other (#8173).

## Decision

1. **Methods are value-generic functions.** A method of a value-generic
   record becomes a function named after the record and generic over its
   parameters, before anything reads the file:
   `func sum(self: in FixedVec[T, N]): Int` is
   `func FixedVec.sum[T, N: Nat](self: in FixedVec[T, N]): Int`.
   - A field or sibling method the body names without `self.` (the
     implicit-`self` spelling) becomes `self.<name>`, unless a parameter or
     local of that name is in scope. `Self` becomes the record's instance
     type.
   - A method without its own visibility takes the record's.
   - `Lyric.Mono` specialises it per length at each call, in whichever
     package makes the call. Inside a specialisation `N` is a constant, so
     `.length`, bounds checks, fills and copies stay constants (D169 item
     5's reason for specialising).
   - A specialisation runs in the consumer's assembly or jar, so a method
     body may use only what a generic function's body may use across
     packages: public items of its package and anything public it imports.
2. **One runtime type on dotnet and the JVM.** A value-generic record is
   emitted once, by the package that declares it, with its value
   parameters erased: `FixedVec[T, N: Nat]` is the class `FixedVec[T]`, and
   every instance in every package names that class. The checker keeps the
   instance type (`TyLen`, D169 item 2), so lengths are still checked and a
   mismatch is still T0060. Contract metadata carries the record as
   written, value parameters included, so a consumer types `FixedVec[Int, 3]`
   from it.
3. **Native keeps per-length records, one per package of declaration.** An
   `array[N, T]` field is an inline `[N x T]` there, so each length is its
   own layout. A native build compiles every package of the project into
   one module; a package that uses another package's record specialises it
   like a local one, and the bridge adds the specialisation to the declaring
   package's output once. Every package then names the one
   `Pkg.FixedVec__V3`.
4. **Lengths bound inside generic code.** `Lyric.Mono` binds a value
   parameter the type checker recorded no length for from the argument's
   type expression, where the length is a literal. So a value-generic
   function, or method, that calls another with its own `N` is specialised
   once the caller is. A method call `v.sum()` whose receiver type names a
   record with a generic function `sum` is specialised as `FixedVec.sum(v)`
   by the same pass, for a generic body from another package that the type
   checker of this package never saw.
5. **T0164 is removed.** A value-generic record may be used from any
   package, through an import or a restored dependency.

## Rationale

- Erasing `N` from the runtime type matches what dotnet and the JVM already
  do with the array fields it sizes. It needs no loader or bundler that
  unifies generated types, which a per-consumer specialisation would.
- Hoisting methods into value-generic functions reuses the length
  specialisation, cross-package body transport and per-specialisation
  re-check that value-generic functions already have, and keeps every
  length a constant.
- Native compiles from source into one module, so moving each
  specialisation to its declaring package is enough to share it.

## Consequences

- D169 item 5 changes on dotnet and the JVM: the record is no longer copied
  per length; only its methods are specialised. Native is unchanged except
  for item 3's placement.
- A value-generic record has no instance methods on dotnet or the JVM; its
  methods are static functions named after it.
- `docs/01` §2.7 drops the package-local restriction, and Appendix B retires
  T0164.
- `value-generic-record-e2e.sh`'s T0164 case becomes a positive case: a
  two-package project where the application builds, passes and calls methods
  on the library's value-generic record, on all three targets.
