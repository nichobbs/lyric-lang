# `array[N, T]` on every target (D167, docs/67 §4.3, G1 #7940)

`array[N, T]`, a fixed-length array with value semantics, now works on
`--target dotnet`, `--target jvm` and `--target native`. Before, dotnet and the
JVM erased it to an untyped object and native did not lower it. D167 items 1 to
5 and 7 are done; item 6 (value-generic `N`) is the next slice.

## Language

- A bracket literal where an array is expected builds one (a binding, an
  argument, a field, a `return`, an `if`/`match` arm, the argument of a distinct
  type's `from`), with exactly `N` elements (**T0155**).
- A declaration without an initializer, and a field with no default (of a
  record, an opaque type or a protected type, which is then not a required
  constructor argument), is zero filled: scalars, enums (first case), distinct types, records of zeros or
  defaults, arrays of those. An element type with no zero is **T0156**.
- An element write needs a `var` local, an `out`/`inout` parameter or a `var`
  field (**T0157**); an element of a `List`, `Map` or slice is not a writable
  place, and an `inout`/`out` array argument must be a writable variable or
  field (T0157; an element or an expression is rejected the same way on every
  target). An index is an integer (`Int`, `Long`, `Byte`, `UInt`, `ULong`) or a
  range subtype of one (**T0158** otherwise; a non-`Int` index is range checked
  as a `Long`, then narrowed). A record or union with a field that holds an
  array anywhere (an `Option`, tuple, collection, alias, nested record or
  union) derives no `Equals`, `Hash`, `Show` or ordering (**T0159**): derived
  code is not lowered by the array pass and would compare the array by
  reference. An unknown member on an array (`a.add(x)`), or `a.toSlice` not called, is **T0113**. A length
  that is neither a compile-time constant from 0 to 2147483647 nor a value
  generic parameter is **T0160** where the type is written; an array whose
  length is a value generic parameter is T0160 where it must be copied,
  indexed, measured, compared, iterated or `.copy`-carried, never a silent
  share. An element of an array passed to an `out`/`inout` parameter needs a
  writable array, like `a[i] = v` (T0157). A bracket literal of arrays copies
  each element array (`[a, a]` shares storage with neither `a` nor itself).
- Copies follow one ownership invariant: every writable place (a `var` local,
  an `out`/`inout` parameter, a `var` field) exclusively owns its storage, and
  storage reachable from an immutable place (a `val`, an `in` parameter, a
  non-`var` field, a collection element, a temporary) is never mutated. An
  array is copied when stored into a writable place (a `var` initialiser or
  assignment, a record construction or `.copy` argument; a call result too,
  since a generic callee may return its argument) unless it is a bracket
  literal of scalars, and when read from a writable place and the read escapes
  (bound, passed to any parameter including `in` and generic ones, returned,
  stored, iterated). A read of an immutable place is never copied; a read
  used at once (index receiver, `.length`, `.toSlice()`, `==`, assignment
  target, `inout`/`out` argument) is not copied. Copies are decided where the
  type is concrete, so generic callees need nothing, and use a capacity hint.
  A closure that reads a captured `var` array shares that variable, as it does
  for any `var`.
- `.length` is the constant `N`; `for x in a` iterates a snapshot; `.toSlice()`
  copies into a new `slice[T]`; `==` / `!=` go element by element (D164 for
  records, nested arrays recursively, T0153 for function elements).
- A NAMED range-subtype index (`type Slot = Int range 0 ..= 3`) whose bounds
  lie in `0 ..= N - 1`, or a literal in range, emits no bounds check, on every
  target and in every build; an inline `Int range 0 ..= 3` annotation does not
  count, because inline ranges are not enforced everywhere (below). An
  out-of-range index panics with `index <i> out of range for array[<N>]`.

## Design

**One lowering for all three targets.** The checker resolves `N` (a literal or a
constant that folds) and records each array operation as a span-keyed site
(`SymbolTable.arrayIndexSites`, `arrayLenSites`, `arraySliceSites`,
`arrayForSites`, `arrayCopySites`, `arrayZeroSites`; equality is
`arrayEqSites`, and a record's `RecordEqSite` carries its array leaves).
`Lyric.ContractElaborator.lowerArrays` (`array_ops.l`) rewrites them in the
shared pipeline, after the distinct, record-arithmetic and record-equality
passes and before the overflow pass (which finds a compound assignment by its
span). The bounds check is explicit code, so the panic message and the
elision are the same everywhere:

```
a[i]  ->  a[__lyric_unchecked({ val i': Int = i
                               if i' < 0 or i' >= N { panic("index " + i'.toString() + " out of range for array[N]") }
                               i' })]
```

The index stays an index, so `a[i] = v`, `a[i] += v` and `a[i][j] = v` remain
writes to a place. `for` becomes a range loop over a snapshot, `.length` the
literal, `.toSlice()` a loop into a `List`, `==` a loop (`arrayEqBlock` in
`distinct_ops.l`, which `recordEqBlock` also calls for an array field). Three
intrinsics are left for the backend: `__lyric_array_fill[array[N, T]](z)`
(`N` fresh evaluations of the zero value `z`), `__lyric_array_copy[array[N, T]](a)`
and the `__lyric_unchecked(i)` index marker. A copy is decided by the checker,
not guessed: every array place read is a copy site, and the consumers that never
store it (an index receiver, `.length`, an `==` operand, an assignment target, an
`inout`/`out` argument, an `in` argument to a Lyric function) exempt it.

**dotnet and the JVM: an array is a `List`.** `lowerArraysToLists` runs last in
`pipeCheckAndMono` when `MiddleEndOptions.arraysAsLists` is set: the fill and
copy intrinsics become loops over `newList()` and every `array[N, T]` type
becomes `List[T]` (`Lyric.TypeAliasResolve` in a reserved mode). Everything a
`List` already has (index, `set`, iteration, element typing, boxing) is reused;
the cost is the boxing of numeric elements, which a typed host array (`T[]`)
would remove (#8041). D167 item 7 said "a host array"; it now
says what is built. The JVM bridge builds its signature, field and case
registries from the parsed file before the middle end runs, so it registers a
copy of each package with the array types already spelled as lists and hands the
middle end the array-typed original (`arrayTypesAsLists`, `arrayTypedOrSelf`).
`pipeParseAndErase` adds `import Std.Collections` to a file that spells
`array[`, before anything resolves imports.

**native.** `array[N, T]` is the LLVM array `[N x T]` when `T` is by-value
(`isByValueFieldNType` now accepts an array of a by-value element), so an array
of floats, enums or `Vec3`s, an array of such arrays, and a by-value record
holding one all allocate nothing and `==`/copy are plain aggregate operations.
Any other element type uses the reference-counted `List` representation, so the
index, assignment and `for` paths are the existing ones, with the fill and copy
intrinsics lowered as IR loops (`lowerArrayFillCall`, `copyArrayValue`; a nested
array is copied deeply). An element is read and written through its address
(`placeNType`/`placeAddr`: a local's slot, a heap record's field, an element of
an inline array), never by loading the whole array. A by-value aggregate in a
`List`/`Map`/`Task` slot is boxed (`isBoxedValueNType`, for records and arrays).
The backend checks an index only when nothing else has (code a pass synthesised
after the lowering): such an access has no `__lyric_unchecked` marker and gets a
fixed-message check, so no access is ever unchecked by accident. An inline array
in an `extern func` signature is `N0010` like a by-value record (C ABI #8009).
The checker resolves every length (a literal, a constant, a constant
expression) and the pipeline rewrites it to its literal before a backend runs
(`withArrayLens`), so codegen never looks a length up by name and cannot pick a
same-named constant from another package.

**Generic specialisations.** A generic body is checked once over `T`, so the
array operations it performs when `T` is an array (a copy of a `T` read out of a
`var`, `==` on two `T`s, a `T` wrapped in an `Option` compared with `==`) are
not visible to the first check. Each specialisation whose type arguments
mention an array is re-checked as the concrete function it is (the #8023
machinery, `recheckSpecs`), and its sites are lowered on that specialisation
alone (`lowerSpecArrays`). The specialisation key includes `N`, so one generic
used with `array[3, Int]` and `array[4, Int]` gets two bodies. `==` on an
`Option`, tuple, union or distinct type that holds an array compares the arrays
element by element (`wrapEqSites`).

## Fixes outside the array code

- JVM: an element write through a field whose type is a type parameter
  (`c.v[0] = 7` with `record Cell[T] { var v: T }`, `T` a `List` or an array)
  called `ArrayList.set` on the erased `Object` and failed verification; the
  write path now casts the receiver as the read path already did.

## Known limits

- Value-generic `N` (D167 item 6) is not implemented; an array with no known
  length is T0160 where it is indexed, measured, copied, compared, iterated or
  `.copy`-carried; it is the next G1 slice (#7940).
- `==` on a type that holds an array is built element by element; a recursive
  type that holds an array has no finite comparison and is T0160.
- A record declared in another package carries no zero default for an array
  field, so constructing it there needs the field given (T0105, #8042).
- A package restored from a built DLL that exposes `array[N, T]` in a
  signature is mapped to a list by the MSIL and JVM backends but is not covered
  by a test (#8042); arrays across the path-dependency packages of one project
  are (`fixed_array_project_self_test.l`).
- A bracket literal is not adopted as an array (or a `List`) inside an
  `Option`/union payload whose type comes only from the expected type
  (`val o: Option[array[2, Int]] = Some(value = [1, 2])` is T0060, as it is for
  `List`); bind the literal to a typed `val` first.
- Inline range annotations are enforced on a function parameter, a return
  value and a `val`/`var` binding, and NOT on a record field (construction or
  assignment), a lambda parameter, a collection element (`List[Int range ..]`)
  or an array element, on dotnet and the JVM; `--target native` rejects an
  inline range type outright. That is why they are not a bounds-check proof
  (#8031).
- A generic record with an array field of element type `T` has no zero value,
  so the field is a required constructor argument; `Box(data = src)` infers `T`
  from a typed array, not from a bracket literal (#8042).
- A large inline array is an LLVM first-class aggregate: moving one by value
  costs a copy and very large ones are slow to compile; `buffer[T]` (docs/67
  §4.4) is the type for bulk data.

## Tests

- `typechecker_self_test.l` (819): sizes and length equality, T0155 in each
  position, T0156, T0157 (collection elements, `inout` arguments, an element
  passed to `inout`), T0158, T0113, T0159 through nested records, tuples,
  slices and aliases and twelve levels down, T0160 on a non-constant length and
  on `.length`, an index, a copy, `==` and `for` of an array with no known
  length and on `==` of a recursive union holding one, T0153 for arrays, the
  index-site elision data (named ranges only), `.length` and `.toSlice()`.
- `fixed_array_self_test.l` (26, dotnet, JVM, native): the ownership copy rule
  (val to var, generic pass-through and results, `in` arguments stored in a
  field, `.copy`, a generic record's array field), compound assignment through
  `a[i + 1]`, `a[f()]`, `c.hits[k * 2]` and a nested element (the call runs
  once), `inout` of a var local and a var field, integer index types, literals,
  nested arrays and records, zero fill, fields, element writes on a `var` local,
  a `var` field, an `inout` parameter and a generic record's field, copy on
  assign/pass/return/field/`.copy`, `.length`, `for` over a snapshot,
  `.toSlice()`, `==` (including inside options, tuples, unions, distinct types
  and records), range-subtype indexes, constant lengths, generics over arrays
  (copies, `==`, iteration, two lengths giving two specialisations), a
  distinct type made from a bracket literal and a bracket literal of arrays
  that copies each element.
- `fixed_array_panic_self_test.l` (7, dotnet, JVM): the panic message for
  reads and writes past either end, nested arrays, fields and an empty array,
  a `Long` index and a compound write through a call index, an index evaluated
  once before the check, a range-subtype index that never panics, and a `ULong`
  range up to 2^64 - 1 that is still checked.
- `scripts/ci/fixed-array-e2e.sh` (8 cases, dotnet, JVM, native): a read, a
  write, a compound write, a negative index, an inner and an outer nested
  index, a field and an empty array each exit non-zero with the exact message,
  after the accesses before them and never reaching the line after.
- `fixed_array_project_self_test.l` (3, one per target): a three-package
  project with an array field, a function taking, mutating and returning
  arrays, a length named by another package's constant, `==` across the
  boundary, and a package that copies an array it only gets through another
  package's function (it never spells an array type).
- `llvm_fixed_array_self_test.l` (13, native, ASan): `[N x T]` IR shape and no
  allocation for floats, `Vec3`s, nested arrays and an array inside a by-value
  record, the backend's own check, a heap array of `String`s and of mutable
  records, deep copies, an IR assertion that a range-subtype or literal index has
  no panic path and an `Int` index does, and N0010.

## Results

All of the above pass. distinct_ops, record_semantics, float32, record_arith,
overflow, record_eq, byvalue_record, inline_union, slice_fastpath and
labelled_loops pass on dotnet, JVM and native; overflow_panic on dotnet and the
JVM; llvm_byvalue_record (38) and llvm_inline_union (23) on native.
