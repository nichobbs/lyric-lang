# MSIL: `var` field write on a generic record silently dropped (#7663)

`box.value = other` where `box: MyBox[T]` (a `record MyBox[T] { var value: T }`
instance) compiled clean on `--target dotnet` but had no effect: the field
kept its constructor-time value forever. `--target jvm` and `--target native`
were both already correct for plain assignment — the lost write was an
MSIL-only codegen bug. Compound assignment on the same field failed to
compile on the JVM; that is fixed here too.

## Root cause

`Msil.Codegen.lowerAssignExprMsil`'s `EMember` arm (`recv.field op= value`,
`lyric-compiler/msil/codegen.l`) dispatched on the receiver's `MsilType`. It
handled `MClass` (a plain, non-generic record or class) and `MClassRef` (an
extern instance) — every other receiver type fell through to a `case _`
default that lowers the value expression for its side effects and then pops
**both** the value and the receiver, emitting no `stfld` at all. A generic
record instance receiver is never classified as `MClass`: it is
`MGenericInst` (a cross-assembly generic, e.g. a stdlib type instantiated
from a restored package) or `MGenericInstByName` (an in-bundle generic record
such as `MyBox[T]`, docs/43). Neither was handled, so every write through a
generic record instance silently no-opped.

The read side never had this gap: `EMember` reads already special-case both
generic-instantiation receiver kinds, narrowing the `object`-typed receiver
to a closed GENERICINST TypeSpec (`MCastclassGeneric`) and reading the field
through a TypeSpec-parented MemberRef (`MLdfldGeneric`) — required because,
per docs/43, an in-bundle generic record is a true open CLR generic
(`GenericParam` table 0x2A), so a bare `TypeDef`-relative field token doesn't
resolve against a closed instantiation; ECMA-335 §III.4.21 requires the
TypeSpec-parented form. There was simply no write-side counterpart.

The bug reproduced regardless of whether the enclosing function was itself
generic — `MyBox[T]` instantiated concretely (`MyBox(value = 1)`) inside a
**non-generic** function hit the same `MGenericInstByName` receiver path and
the same silent drop. It also reproduced identically for `val`- and
`var`-bound bindings: per docs/01 §"mutable fields", a record's own `var`
field is writable through the binding regardless of whether the local
binding itself is `val` or `var` — only the mode checker's V0015 governs
whether a *non*-`var` field write is rejected. This fix makes a generic
record behave identically to a non-generic one for that rule; no language
reference change was needed since the documented semantics were already
correct — only the MSIL emitter's codegen disagreed with them.

## Fix

Added the write-side analog of `MLdfldGeneric`:

- **`lyric-compiler/msil/lowering.l`**: a new `MStfldGeneric` `MInsn` case,
  lowered identically to `MLdfldGeneric` (same closed GENERICINST TypeSpec +
  TypeSpec-parented MemberRef construction, resolving the owning TypeDef or
  falling back to a TypeRef) but emitting `stfld` instead of `ldfld`.
- **`lyric-compiler/msil/codegen.l`**: `lowerAssignExprMsil`'s `EMember` arm
  gained `MGenericInst` and `MGenericInstByName` cases, mirroring the
  existing read-side lookups (field-var-index / FieldSig-bytes / field-token
  presence checks, open vs. substituted-concrete field type) to build the
  `MCastclassGeneric` + `MStfldGeneric` (plain assignment) or
  `MCastclassGeneric` + `MDup` + `MLdfldGeneric` + combine + `MStfldGeneric`
  (compound assignment, e.g. `box.value += x`) sequence. Also added the
  `MStfldGeneric` stack-delta entry (`-2`, matching `MStfld`) to the
  instruction-size cost table.

Plain assignment needed no JVM or native change: `Jvm.Codegen`'s
field-assignment lowering resolves a record field's `putfield` descriptor
from the record's own declaration regardless of receiver classification, and
native's generic-record codegen (docs/N3.1 monomorphization) was never on
this path either.

Compound assignment (`box.value += 5`) on the JVM, however, failed to
compile (J008, "compound assignment on a reference-typed target"): the field
is stored as erased `Object`, and the combine had no concrete type to work
at. `Jvm.Codegen.genericFieldCombineType` (`05_stmts.l`) now resolves the
field's type-parameter index (`JvmCaseField.paramIdx`) against the
receiver's instantiation (`scrutineeGenericArgs`, the resolution
match-payload unboxing already uses), unboxes the current value to that
type, combines, and re-boxes it for the `putfield`.

## Tests

New dual-target self-test:
`lyric-compiler/lyric/generic_record_var_field_self_test.l` (13 cases) —
`val`-bound and `var`-bound generic record instances, a `var` field write
through a captured closure, two sequential writes, both `Int` and `String`
type arguments, and a generic record instantiated inside a **non-generic**
function (isolating the bug from `Lyric.Mono` monomorphization), plus three
compound-assignment cases (`+=`/`-=`/`*=` on `Int`, `+=`/`*=` on `Long`
with an `Int`-literal operand, `+=` on `String`, `+=` through a captured
closure). Verified to
fail against the pre-fix compiler and pass (all 13, both
targets) against the fix. Wired into
`scripts/ci/compiler-self-tests-batch.sh` (dotnet) and
`scripts/ci/jvm-generics-self-tests-batch.sh` (jvm).

## Out of scope (filed as a separate finding, not fixed here)

A closure that only **reads** a generic record's `Int` field it captured —
no write through the closure at all — returns a garbage value on
`--target dotnet`:

```lyric
func readViaClosure[T](seed: in T): T {
  val box = MyBox(value = seed)
  val get = { -> box.value }
  get()
}
```

Confirmed pre-existing on `main` before this fix (the read path this fix
does not touch), and confirmed NOT triggered by the `String` type argument
in the same shape — only `Int` (and presumably other value types) reproduce
it. Likely a hoisted-closure-capture-cell / `MLdfldGeneric` field-type
interaction distinct from #7663's write-side bug. Tracked in #7671.

## Correction to D-progress-1021

`docs/decisions/D-progress-1021-std-task-runwithin-jvm-timeout.md` (#7461)
records this bug as reproducing "on both targets". That is wrong: its own
minimal repro (`myFn[T]` writing `box.value` inside a generic function)
returns the written value on `--target jvm` with a compiler whose JVM
backend is unchanged from `main`, and this PR's plain-assignment self-test
cases pass on the JVM without any JVM change. The silently dropped write was MSIL-only; the JVM
gap this PR also closes (compound assignment, above) was a compile-time
error, never a lost write.

`Std.Task.runWithin` (both kernels) keeps its captured `List` as the
one-slot result cell: it is a sound implementation on its own. The kernel
comments that justified it by this bug are replaced with the plain
rationale (keeping `T` off the BCL/JDK boundary).
