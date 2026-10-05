# Value-generic records across packages (#8150)

D173. A value-generic record (`record Vec[N: Nat]`, D169) may now be used
from any package, through an import or a restored dependency, on dotnet, the
JVM and native. T0164 is retired.

## Before

Each package specialised a value-generic record into its own types
(`Vec__V3`), so two packages would have had two runtime types for one Lyric
type. A use from another package was T0164.

## Change

- **Methods are value-generic functions.** `Lyric.Pipeline` turns each
  method of a value-generic record into a function named after the record
  and generic over its parameters (`func Vec.total[N: Nat](self: in Vec[N])`)
  as the file is parsed (`hoistValueRecordMethods`). A field or sibling
  method named without `self.` becomes `self.<name>` unless a parameter or
  local of that name is in scope. `Self` becomes the instance type, and a
  method without its own visibility takes the record's. `Lyric.Mono`
  specialises each per length at the call (#8173).
- **One type on dotnet and the JVM.** The middle end erases the value
  parameters (`eraseValueRecords`): the record is one class, and every
  instance, of a local or an imported record, names it.
  - Contract metadata keeps the record as written, and keeps each signature,
    field and union case type that erasure shortened
    (`withValueRecordsAsWritten`).
  - MSIL drops value arguments when it maps a type read from another
    package's contract, and counts only type parameters in a restored
    record's arity.
  - The JVM registers a record with value parameters only as a non-generic
    class, also within its own package.
- **Native keeps per-length records.** A package specialises another
  package's value-generic record like its own. The bridge adds each such
  specialisation to the declaring package's unit once
  (`withForeignValueRecords`), so every package names one `Vec__V3`.
  - The bridge gives the middle end the other packages' value-generic
    functions, since codegen has no value-argument form.
  - A bare call to a dot-named function inside a method is no longer
    taken for a sibling method of `self`.
- **Lengths inside generic code.** `Lyric.Mono` now handles three cases it
  used to miss:
  - **Value parameters with no checker site.** It binds them from the
    argument's type expression, so a value-generic function that passes
    its own `N` to another is specialised. Before, this was M0002 on every
    target.
  - **Method and type-qualified calls in foreign bodies.** It rewrites
    `v.m()` and `Vec.m(v)` to the dot-named function, for a generic body
    from another package that this package's checker never saw.
  - **Value arguments in field types.** Field types of a value-generic
    instance substitute them.
  - A re-checked specialisation also marks its value-record constructions.

## Tests

- `value_generic_record_self_test.l` (9 cases) and
  `dotted_generic_func_self_test.l` (5) pass on all three targets.
- `scripts/ci/value-generic-record-e2e.sh` replaces its T0164 case with two
  positive ones:
  - a two-package project in which the application builds the library's
    record at two lengths, calls its methods (one calling another), passes
    one to a library function taking `Vec[3]`, gets one back from a
    function returning `Vec[2]`, and zero fills one from its type;
  - the same application against the library built as its own project and
    restored from its contract.
