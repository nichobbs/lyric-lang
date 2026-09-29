# By-value `Self` parameters: a regression test on both targets, a JVM frame fix, and generic targets (#7755 follow-up, #7704)

#7755 narrowed a by-value non-receiver `Self` parameter (`other: in Self`) on
MSIL with a prologue `castclass` into a class-typed local
(`narrowSelfParamsMsil`), but it had no dedicated regression test and skipped
generic targets, whose bare TypeDef is not a cast target. Writing that test for
both targets turned up three more problems, all fixed here.

- **Type checker.** A record or impl method body substituted `Self` in its
  return type but not in its parameter types, so a `Self` parameter passed to a
  bare sibling call (`pickSelf(false, other)`, whose registered signature has
  `Self` already substituted) was T0043 "argument type Self does not match
  parameter type Acc", for a generic and a non-generic target alike.
  `substitutesSelfParams` now applies the same substitution to the parameters
  (`checkRecordMemberBodies`, `checkImplMemberBodies`).
- **JVM frames** (`emitSelfParamChecksJvm`, `06_items.l`). The `checkcast`
  narrowing (#6426) stored the narrowed value back into the parameter's own
  slot. The StackMapTable builder types a parameter slot from the method
  descriptor and honours `LAstoreAs` only for a non-parameter local, so every
  branch-target frame after the prologue still typed the value `Object`; a
  field read after an `if` (`if useMine { return … }; other.total`) failed
  class loading with `VerifyError: Bad type on operand stack`. A by-value
  parameter is now narrowed into a fresh local the name is rebound to, as
  MSIL does; an `inout` parameter's value already lives in a non-parameter
  local and keeps the in-place store its holder write-back relies on.
- **Generic targets on MSIL.** Inside a method of `Box[T]` (its own, or an
  impl's, #7704) `Self` is the open instantiation `Box`1<!0>`, which is a valid
  cast target through its TypeSpec. `narrowSelfParamsMsil` now casts to it
  (`MCastclassGeneric`) and tracks the parameter as that instantiation, so
  `other.value` reads the `!0` field through the same TypeSpec-parented
  reference `self.value` uses. A bare sibling call and a bare field reference
  on a generic `self` are lowered as `self.<name>(…)` / `self.<name>`, since
  the plain MethodDef/FieldDef token they used is invalid on a generic class;
  the generic-receiver call path already casts a `Self` result to the
  receiver's instantiation, so `narrowSelfCallResultMsil` keeps skipping
  generic classes. A closure that captures such a parameter stores it in an
  `object` field: a lifted lambda is a static method of the non-generic
  package class, where `!0` means nothing, so #7695's erasure of a captured
  bare `!0` now covers any captured type that mentions one
  (`msilTypeHasDanglingTypeVarMsil`).

A closure inside a generic method that reads a `T`-dependent member of a
captured `self` or `Self` parameter (`{ -> r = self.value }` in a `Box[T]`
method) still cannot be compiled for `--target dotnet`: the lifted lambda has
no type parameters, so the captured value is an `object` whose `!0` field it
cannot name, and the run fails with `TypeLoadException`. That is a
pre-existing limitation of lifting closures to non-generic methods (it
applies to a record's own methods as much as to impl methods); `--target jvm`
is unaffected. Reading the field into a `T` local outside the closure and
capturing the local works on both targets.

## Verification

`impl_generic_target_self_test.l` adds `Mergeable` (`Self` parameters and
returns) and `Combine` (an explicit `self: in Self` receiver) impls for both
the generic `Box[T]` and a non-generic record, each body reading the `Self`
parameter's fields, passing it to a bare sibling call, and declaring `T`
locals, including a closure-captured one. Both targets pass and the dotnet
DLL is ilverify-clean (the test is in `scripts/ilverify-selfhosted.sh`'s
phase 4). Before: the file did not type-check on either target (T0043 on the
two bare sibling calls passing a `Self` parameter); with the type checker
fixed, the non-generic record's `pickSelf` failed JVM verification, and on
dotnet the generic cases failed at run time (`BadImageFormatException`, then
`TypeLoadException` for the closure field) with up to 5 ilverify errors.
