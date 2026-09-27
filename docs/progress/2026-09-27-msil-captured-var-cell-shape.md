# MSIL: a closure-captured `var` record local no longer throws `NullReferenceException` (#7460)

A `var` referenced inside a lambda is hoisted to a shared heap cell (#1479 v2),
so the closure and the enclosing scope read and write one location. On
`--target dotnet` the cell had two shapes: a typed one-element array for the
scalar, `String` and `Object` element types, and a `List<object>` for
everything else (records, unions, slices, collections).

The declaration site picked the shape before it lowered the initializer, and
it used only the annotation to decide. An un-annotated `var` fell back to
`Object`, so `var b = Box(n = 1)` built an `object[]`. `finishHoistedCellMsil`
then saw the record element type, chose the `List<object>` path and called
`List<object>.Add` on the array. The cell stayed empty, and the first read or
field write through `b` threw `NullReferenceException`. An un-annotated
`var xs = [1, 2, 3]` failed the same way. A scalar `var i = 0` got an
`object[]` cell that every read, write and closure field declared as
`int32[]`. The `List<object>` cells were declared as `object` slots and fields,
so each `get_Item`/`set_Item` on them failed ILVerify (`StackUnexpected`). A
hoisted `var` of a reference type with no initializer was seeded with a boxed
`0` instead of `null`.

A cell is now always a one-element CLI array. `cellStorageElemTyMsil` in
`lyric-compiler/msil/codegen.l` gives its storage element type: the element
type itself for the scalar, `String` and `Object` types, and `object`
otherwise, with values boxed on store and cast back on load. A `slice[T]` with
an array-token element is narrowed back to the `T[]` that the rest of the
backend declares for slices. Five sites derive the cell's shape from that one
function:

- the declaration (`finishHoistedCellMsil`)
- the enclosing-scope read
- the closure-side read (`emitCellElemLoadMsil`)
- writes and compound assignments (`emitCellAssignMsil`)
- the synthesized closure-class field (`synthesizeClosureClassMsil`)

The declaration builds the cell after the initializer is lowered. With no
initializer, it seeds the cell with the type's default (`pushDefaultValueMsil`).
The `List<object>` cell path is gone. The JVM backend already built its cell
after the initializer and gave correct results for every shape.

`lyric-compiler/lyric/closure_var_capture_self_test.l` has 18 runtime cases
on both targets:

- `var` and `val` record captures, with field writes inside the closure read
  after it
- reassignment of the whole `var`, and copy-and-reassign
- compound field assignment (`b.n += 1`, `b.label += "bc"`)
- outer writes after closure creation, read inside the closure
- two closures sharing one cell, and nested closures that write a field or
  reassign the `var` two levels down
- `Int`, `Long` and `String` `var`s, a `slice[Int]` (element write and
  reassignment), a `slice[Box]`, and a `List[Int]`
- `var`s declared without an initializer and assigned inside the closure

Before the fix, 9 of those cases failed on dotnet. All pass on both targets
now. The test runs in `scripts/ci/compiler-self-tests-batch.sh` (dotnet) and
`scripts/ci/jvm-generics-self-tests-batch.sh` (JVM). ILVerify reports no cell
errors in the emitted DLL. The only errors left are the `DelegateCtor` errors
that every `() -> Unit` lambda argument produces, which #7166 tracks.
