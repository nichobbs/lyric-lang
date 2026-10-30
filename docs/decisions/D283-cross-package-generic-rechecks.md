# D283 - Cross-package generic specialisations: the caller's types in scope, own unsigned operands, expected-type case constructors

**Status:** accepted, implemented (#8530, #8019, #8481); supersedes item 4 of D224 (the M0008 restriction); follow-up to D273

## Context

A generic from another package is compiled into the caller. Where the checker records something a generic body
checked over its type parameters cannot (unsigned operands, `+` on a distinct type, a record's derived operator),
`Lyric.Pipeline` checks the specialisation again as the non-generic function it is, in the scope of the package that
declares the generic.

1. **#8530.** That scope does not see a distinct or record type the caller declares, so a specialisation of an
   operator-bounded generic (`where T: Add`) at such a type was the hard error **M0008** (D224 item 4).
2. **#8019.** Only a specialisation whose *type arguments* mention `UInt`/`ULong` was checked again. A generic whose
   own body holds concrete `UInt` locals (a hash helper) and is specialised at `Int` was never checked, so its
   comparisons and `/`, `%` on values at or above 2^31 lowered as signed (JVM: `-184995328 0 false -1294967296`
   for `3000000000 / 7`, `% 7`, `> 7`, and the value itself).
3. **#8481.** Two unions of one package may share a case name. The checker resolves a bare constructor
   (`return Both(n = 2)`) against the expected type, but the JVM and native backends looked the name up in a
   package-wide table that holds one union's case (JVM: the last declared, native: the first), so the other union's
   function failed with a `ClassCastException` (JVM) or `N0007` (native). dotnet resolved it correctly.

## Decision

1. **The caller's types join the origin scope.** `addConsumerTypes` adds the type declarations of the file being
   compiled (alias, distinct type, record, exposed record, union, enum) to the scope in which a foreign specialisation
   is checked, except a name the generic's package already declares. A specialisation whose operator-bounded parameter
   is bound to such a type is checked there, its distinct-type and record-arithmetic sites recorded like any other
   foreign specialisation's, and M0008 is removed. A caller type hidden by a same-named type of the generic's package
   fails the body check and is reported as M0007 (the existing check-failure diagnostic).
2. **A foreign generic that spells `UInt`/`ULong` is checked again.** `specMentionsUnsigned` is true when the
   specialisation's parameter or return types, a local binding's annotation, a lambda parameter type, a type
   argument, a suffixed literal (`u32`, `u64`), `toUInt`/`toULong` or a `UInt.`/`ULong.` path appears in it. Every
   such specialisation of another package's generic is checked again whatever its type arguments are.
3. **A case constructor is the expected union's case.** The JVM (`ctorClassForExpecting`, via the full-class
   expectation the enum cases already use) and native (`tryLowerConstruct`, via the call's expected type) pick the case
   of the expected union before the package-wide table.

## Limits

- An unsigned operand that no spelling in the generic body reveals (a field of type `UInt` read from a record, the
  result of a call to a function returning `UInt`) is not detected by 2. Recording the unsigned sites when the
  declaring package is checked and carrying them in contract metadata is the complete fix and stays open (#8019).
- A bare *nullary* case shared by two unions of one package (`Idle` in both) is rejected by the checker when the
  expected union is not the last declared (T0065/T0043); the checker, not a backend, resolves it. Not addressed here.
- The cross-package form of #8481 (two packages each declaring a union with the same case name) is not covered by a
  new test.
