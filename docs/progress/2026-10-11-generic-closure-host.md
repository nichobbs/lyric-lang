# Lambdas in generic contexts on dotnet: generic closure classes (#8284, #7792, #8205, #8292, #7671)

On `--target dotnet` every lambda was lifted to a static method of the
non-generic package class, where the type parameters of the member that built
it do not exist.  Three failures followed:

- A lambda in a member of a generic record, generic `impl` target or generic
  protected type that read the receiver (`self.n`, a bare field, `val me =
  self`) produced unverifiable IL or a `TypeLoadException` (#7792), and since
  #8264 was rejected with **F0048** (#8284).
- A closure call whose result is a type parameter stored the closure's boxed
  `object` result into the `T` slot without `unbox.any !0`, so a value-type `T`
  read the object reference's bits (#8205).
- A closure called through a generic function's `List[(T) -> T]` parameter
  returned garbage after specialisation (#8292).

What changed:

- `Msil.Codegen.liftLambdasMsil` marks each lambda lifted out of a member of a
  type with type parameters (and each lambda nested in one) with the type's
  parameters.  Such a lambda is hosted by a closure class generic over them:
  its body is an instance method of `__Closure_<i>`<k>`, its captures keep
  their own types (`!0`, `Box`1<!0>`) instead of erasing to `object`, and it is
  built at the enclosing member's own `!0..!n` (`MNewobjGenericByName`,
  `MStfldGeneric`, and the new `MLdftnGeneric`, a TypeSpec-parented `ldftn`).
  `addPackageTokens` gives a hosted lambda no package-class MethodDef row; the
  method signature comes from one function (`lambdaMethodSigMsil`) for both the
  method and its `ldftn` reference.  F0048 and its pipeline check are removed.
- A function value's result typed by a type parameter is unboxed through the
  VAR/MVAR TypeSpec (`materializeBoxedElemMsil`), and a hosted lambda boxes a
  `T` result the same way.  A function-typed parameter's or local's annotation
  resolves in the body's type context, so `T` is `!0` in a generic type's
  member and erased in a generic function.
- The type checker spells a type parameter by its name in the types it
  records for an unannotated function-valued local and for a call through a
  function value (`localBindingTypeSites`, `funcValueCallSites`), on every
  target, so `Lyric.Mono` writes the specialised type into each specialisation
  and the call's result is unboxed (#8205, #8292).  `typeExprsForRefV` now
  passes that choice on to a function type's parameters and a tuple's
  elements; it had dropped it, so the native-only spelling never applied to
  them either, and native rejected #8292's repro at compile time (N0007).  It
  now runs on native too.
- A lambda parameter's annotation may name the enclosing declaration's type
  parameters (`{ x: T -> x }` in a generic record method was T0010 on every
  target); on the JVM such a parameter erases to `Object`.

- Where the checker cannot name a closure's result type (it types a field
  read through a type parameter, `box.value` for `box: MyBox[T]`, and a
  pattern variable of one as unknown, `eraseTyVars`), the call's `object`
  result is converted where it lands: a return (`coerceTrailingToRetMsil`),
  an annotated binding or argument (`coerceCallArgMsil`), an assignment to a
  local or field (`coerceObjectToSlotMsil`), and the join of `match` arms or
  `if` branches whose other arms yield a type parameter or value type
  (`unboxObjectArmsMsil`), all unbox it.  That closes #7671's unannotated
  form, a closure capturing a pattern-bound `T`, a closure reading
  `self.inner.value`, and a lambda in an interface default reading `self`
  (which also returned garbage on a non-generic implementer).  A closure
  returning a concrete `List`/`Map` is cast to it.  On native such an
  unannotated closure is rejected at compile time (N0007), as before.
- A record or `impl` method's own type parameters (`func map[U]`) erase to
  `object` in its body on dotnet, beside the type's reified ones, so
  `{ x: U -> x }` and an unannotated closure local no longer name a bogus
  `Pkg.U` class (W0003).  On the JVM they erase to `Object` in the method's
  descriptor and body, which fixes `NoClassDefFoundError: Pkg/U` for such a
  lambda parameter and for an unannotated closure in such a method (#8298).
- A captured `var` of a type parameter now uses a typed `!0[]` cell, since
  every place it lives is generic over that parameter.

Verified by `generic_closure_self_test.l` (13 cases, value- and reference-type
instantiations, on dotnet, JVM and native, wired into the compiler, JVM
generics and native batches and `scripts/ilverify-selfhosted.sh`) and
`self_fields_self_test.l` (rewritten to check that receiver reads inside such
lambdas resolve to `self`, now that F0048 is gone).
