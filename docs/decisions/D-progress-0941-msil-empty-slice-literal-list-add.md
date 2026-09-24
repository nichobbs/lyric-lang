# D-progress-941 — MSIL: an empty slice literal added to a `List[slice[T]]` no longer builds a mistyped `List<object>` row (#6945)

**Status:** shipped

**Context.** #6945 was filed by the JVM `List[slice[T]]` construction fix
(#6546, D-progress-911) — that fix's own new test file included an "empty
slice element" case the header explicitly marked JVM-only, because the same
case crashed on `--target dotnet` with a different, unrelated, pre-existing
MSIL bug:

```
xs.add([])
xs.add([9])
```

```
Unhandled exception. System.ArrayTypeMismatchException: Attempted to
access an element as a type incompatible with the array.
   at System.Collections.Generic.List`1.AddWithResize(T item)
```

**Root cause.** `Msil.Codegen`'s `EList` (bracket-literal) lowering
consults a `collExpect` stack — the surrounding context's expected
construction type — to decide what representation to build: a genuine
`T[]` array (`newarr` + `stelem`) when the context names one, or,
lacking any hint, `inferHomogeneousListElemTypeMsil` infers `T` from the
literal's OWN elements when they are homogeneous and simple (`[9]` →
`Int32[]`). An EMPTY literal (`[]`) has no elements to infer a type from,
so that inference always returns `None`, and the no-hint arm falls back to
the LEGACY path: a real `System.Collections.Generic.List<object>`
instance, not an array at all.

`List[T].add(value: T)`'s own codegen (the `memberName == "add"` handler)
never pushed a `collExpect` hint for the argument it was about to lower —
every other call-argument site in the file does this (e.g. the
"concrete-collection parameter" fix a few hundred lines above this one,
#6369), but the `.add()` builtin intercept, added earlier for a different
reason (#1964, propagating `contextHintTyArgs` so `xs.add(None)` builds the
right closed generic case), never got the equivalent `collExpect` push.
So `[]` always fell to the no-hint `EList` arm regardless of the
receiver's own declared element type.

`collBoxIfNeeded` — called right after lowering each `.add()` argument —
is a documented no-op for a CONCRETE collection receiver (`isConcreteCollTy`
true for `MConcreteList`): it only boxes for the legacy erased `List<object>`
path, trusting that a concrete-collection call site already produced the
exactly-right closed-generic representation. That trust was misplaced for
`[]`: the mistyped `List<object>` instance reached `List<T>::Add(!0)` (T =
`Int32[]` for `slice[Int]`) completely unconverted. `List<T>.AddWithResize`
internally does `_items[_size] = item` through a `stelem` on the backing
`T[]` array (`Int32[][]` here) — a reference-array element store, which the
CLR checks covariantly at runtime — and a `List<object>` object is not
assignable to `Int32[]`, so the store throws
`ArrayTypeMismatchException: Attempted to access an element as a type
incompatible with the array.`

Confirmed pre-fix repro (`--target dotnet`):

```
package Repro
import Std.Core
import Std.Collections

func main(): Int {
  val xs: List[slice[Int]] = newList()
  xs.add([])
  xs.add([9])
  0
}
```

```
Unhandled exception. System.ArrayTypeMismatchException: Attempted to
access an element as a type incompatible with the array.
   at System.Collections.Generic.List`1.AddWithResize(T item)
   at Repro.Program.main()
```

**Fix** (`lyric-compiler/msil/codegen.l`, the `memberName == "add"`
handler): before lowering a SINGLE-value `.add()` argument (`args.count ==
1`, excluding the two-arg `Dict.add(key, value)` shape, which already has
its own key/value `contextHintTyArgs` handling), push the receiver's own
element type onto `collExpect` when the receiver is a concrete `List<T>`
(`MConcreteList(e)`), pop it after. This routes `[]` — and every other
`.add()` argument — through the SAME `MArray(e)`-hinted `EList` arm a
normal `slice[Elem]`-parameter call site already uses, so `[]` now builds a
genuine zero-length `Int32[]` (`newarr int32; ldc.i4 0`) exactly like `[9]`
already did. Mirrors the JVM sibling fix's shape (D-progress-911: intercept
`.add`, route the argument through the array-producing coercion the
receiver's element type calls for) even though the two backends' root
causes are unrelated (JVM: `List[T]` erases to `ArrayList` and dispatches
`.add` through the generic JDK auto-FFI resolver, opaque to
`slice[T]`/`List[T]`; MSIL: `List[T]` is a real closed generic and never
goes through auto-FFI at all — the gap was purely a missing `collExpect`
push in the `.add()` builtin's own argument-lowering loop).

**Scope.** MSIL-only, matching the tracking issue's own scope (the JVM
bugs #6546 fixed are structurally different and were already resolved).

**Verification.** Repro above: `System.ArrayTypeMismatchException` before
the fix, exit 0 after. `lyric-compiler/jvm/list_of_slice_construction_jvm_self_test.l`
(the JVM fix's own test file, imports only `Std.*`, generic across both
targets) now wired into CI on `--target dotnet` too
(`compiler-self-tests-dotnet-a`), alongside its existing `--target jvm`
run (`compiler-self-tests-jvm`): 4/4 on both targets, including the
previously-crashing "an empty slice element added to a List[slice[Int]]
does not crash" case. No regression: `list_literal_index_self_test.l`
7/7, `msil_project_bridge_self_test.l` 65/65 — both against a full clean
rebuild (`rm -rf .bootstrap/stage1 bootstrap/src/Lyric.Cli.Aot/{bin,obj}`
then `make lyric`).
