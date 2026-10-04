# Value-generic records: a record's `N: Nat` sizes its array fields (#8090)

D169. A record or exposed record may now declare value generic parameters
beside its type parameters, and size its array fields with them:

```lyric
record FixedVec[T, N: Nat] {
  var data: array[N, T]
  func last(self: in FixedVec[T, N]): T = self.data[N - 1]
}
```

Before this change such a field was T0160. This completes D167 item 6 for
records, on dotnet, the JVM and native.

## Checker

- **Instance types.**
  - `FixedVec[Int, 3]` is a `TyUser` whose argument at a value parameter's
    position is the new `TyLen(n)`. Inside a value-generic body it is the
    `TyVar` of an enclosing value parameter.
  - `resolveType` reads the record's generic parameters to tell a length
    position from a type position.
  - A length argument may be a literal, a constant (recorded in
    `valueTypeArgSites`) or a value parameter.
  - A wrong-kind argument is T0163.
- **Array lengths.** `TyArray` gains `sizeVar`, the value parameter its
  length names when the length is not yet known. `substituteTyVars` fills it
  from a `TyLen`, so a field of an instance has its concrete length.
- **Construction.**
  - The length is inferred from an array field argument (`findGenericInPair`
    binds the parameter to the argument's length), or from the expected
    type, which zero fills the array.
  - Two fields giving different lengths are T0043.
  - Each construction's lengths are recorded in `valueRecordCtorSites`.
- **Value-generic functions.** A value-generic function binds `N` from a
  record argument's instance (`bindArrayLengths`) and gives its result the
  bound length (`withBoundArrayLengths`).
- **Record methods.** A method sees the record's value parameters as `Int`
  constants and defers its length checks, like a value-generic function body
  (`withOwnerValueGenerics`).
- **Other kinds of type.**
  - A union's value parameter sizing an array keeps T0160 and names #8149.
  - Opaque and protected types now report it too. Before, they slipped
    through unchecked.
- **Packages.** Using another package's value-generic record is T0164
  (#8150).

## Middle end (`Lyric.Pipeline`)

1. **Before `Lyric.Mono`**, `markValueRecordCtors` spells each construction
   with its lengths (`Ints[3](...)`, or `Ints[N](...)` in a value-generic
   body).
   - Mono's value substitution now also substitutes a type-application's
     type arguments (`substExprValue`, `substTypesExpr`), so a specialised
     function's constructions become concrete.
2. **After it**, `specialiseValueRecords` gives each instance its own record:
   - The record is named `FixedVec__V3[T]`. Its lengths are substituted in
     fields, invariants and methods (`Mono.specializeRecordValues`), and its
     type parameters are kept.
   - It renames every reference through new `Lyric.TypeAliasResolve` markers.
   - It repeats until no new instance appears, since a field may be another
     instance.
3. **Then** `lowerValueRecordSpecs` checks each specialisation again from the
   record's source, with the other specialisations as signatures. It lowers
   the array operations the check records in its methods, as a value-generic
   function's specialisation is lowered. A method that does not type-check
   at an instance's lengths is M0007.

## JVM

The bridge registers the specialised records' methods and fields from the
post-mono file (`collectValueRecordSpecSigs`). Before, a method call on one
fell back to the `()Object` guess.

## Verification

- `value_generic_record_self_test.l`: 9 pass on dotnet, the JVM and native.
  It covers:
  - length from a field, from the expected type and from a constant;
  - two instances with their own methods;
  - `N` in a method body;
  - field writes and copies;
  - a mixed type and value record;
  - value-generic functions over instances;
  - nested arrays;
  - `==` on a value instance;
  - a record field that is another instance.
- `typechecker_self_test.l`: 845 pass, with new tests for instance typing,
  T0043, T0163 and the T0160 cases on unions and opaque types.
- New `scripts/ci/value-generic-record-e2e.sh`, run on all three targets
  from the compiler and native batches:
  - a two-package project where the library uses its own value-generic
    record behind a public function builds and runs;
  - the application naming that record is T0164.
- The dotnet compiler self-test batch, the native backend self-tests and the
  JVM self-tests CI runs pass.

## #8148 review suggestions

- `scripts/ci/jvm-typed-arrays-nobox.sh` also checks an array of arrays: an
  `ArrayList` of typed rows whose elements are read without boxing.
- `fixed_array_self_test.l` adds a case reading arrays through erased values
  (a slice of `Float` rows, a generic function's `Byte` result, a slice of
  `Bool` arrays). On the JVM these go through the runtime-dispatching index
  helpers. It passes 31 on all three targets.

## Follow-ups

- #8149: value parameters on unions, opaque and protected types.
- #8150: cross-package value-generic records.
