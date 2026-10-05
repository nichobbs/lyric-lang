# Value-generic unions and opaque types (#8149, D175)

An opaque type and a union may now declare value generic parameters that size
their array fields, as a record has since D169:

```lyric
pub opaque type Window[N: Nat] {
  var cells: array[N, Int]
}

pub func Window.total[N: Nat](self: in Window[N]): Int { ... }

pub union Shape[N: Nat] {
  case Poly(pts: array[N, Int])
  case Empty
}
```

Both run on dotnet, the JVM and native, in their own package and from another
package, through an import or a restored dependency. A protected type's value
parameter still cannot size an array field (T0160): native has no generic
protected types yet (#7864).

## Change

- **Checker.** An opaque type's or union's value parameters are told from its
  type parameters where an instance is written (`Shape[3]`). A record or
  opaque construction binds them as before; a union case construction binds
  them from its array arguments or the expected type, and is recorded with
  its union and lengths (`SymbolTable.valueUnionCtorSites`), as is a reference
  to a case with no fields. An opaque type's field read in its own package is
  typed against the receiver's instance, so `self.cells` in `Window.total` is
  an `array[N, Int]`. T0160 now fires for a protected type's field only.
- **Pipeline.** An opaque type's fields, and a union's case fields in order,
  are a record view that the value-generic record passes specialise (native)
  or erase (dotnet and the JVM); the result is put back as the opaque type or
  union it was. On native a recorded union construction is spelled with its
  union and lengths before monomorphisation and becomes a construction of the
  specialisation's case after it (`Shape__V3.Poly(...)`); a qualified pattern
  (`case Shape.Poly(p)`) drops the union name, since a pattern resolves its
  case by the scrutinee's type. Contract metadata carries both as written.
- **Native.** A generic union case construction binds a type parameter from
  any field type that mentions it (`items: array[2, T]`), not only from a
  field typed as the bare parameter. The bridge places a union specialised
  for another package in that package, as for records (D173 item 3).
- **MSIL.** A union's CLR generic arity counts its type parameters only.
- **JVM.** An opaque type or union whose only generic parameters are values is
  one non-generic class, registered as such in its package. Each package of a
  bundle now learns which classes of the other packages are opaque, so a
  specialisation of another package's generic function reads an opaque field
  through its accessor. This also fixes such a read for a type-generic opaque
  type across packages, which failed with `NoSuchFieldError`.

## Tests

- `value_generic_record_self_test.l` gains an opaque `Window[N]` case and two
  union cases (`Shape[N]` and `Tagged[T, N]`): constructions binding the
  length from an array or the expected type, a construction inside a
  value-generic function, bare and qualified patterns, a case with no fields,
  a heap element array, and a type parameter beside the length. 13 cases on
  all three targets.
- `typechecker_self_test.l`: no diagnostic for a union's or opaque type's
  array field sized by its parameter, a mismatch for a `Shape[2]` where a
  `Shape[3]` is expected (T0043), and T0160 naming #7864 for a protected type's.
- `value-generic-record-e2e.sh` adds `pub opaque type Win[N: Nat]` and
  `pub union Path[N: Nat]` to its library, used from an application in the
  same project and from one that restores the library, on all three targets.
  The restored application calls a non-generic wrapper instead of `Win.sum`:
  on dotnet a restored generic function over a generic opaque type fails
  whether its parameters are types or values (#8187).
