# D231 - A bare type parameter is rigid in more places; explicit constructor type arguments and overloaded protected members are rejected

**Status:** shipped (#8332, #8449, #8018, #7786, #7978, #8104).

## Context

The `group:typechecker-diagnostics` issues share one cause: `typeEquiv` treats a type variable as a wildcard, because
the same `TyVar` also stands for a callee's instantiation variable, and several places the checker gave up on a
`T`-typed value by erasing it to `TyError`. Four accepted-invalid programs resulted:

- a bare `T` where a `Bool` is required (`while x`, a contract clause, a quantifier body, an operand of `and`/`or`) was
  accepted; only `if` and match-guard conditions rejected it (#8332);
- a field declared as the record's own type parameter (`Box[T].v`), read through an instance at the enclosing
  generic's type parameter, was typed `TyError`, so `bump(b.v)` against an `inout Int` parameter, or `val n: Int = b.v`,
  type-checked and produced ill-typed IL (#8449, #8018);
- `Box[Long](value = 5)` (explicit type arguments on a record constructor) reached code generation and failed there
  with "reference 'Long' resolves to no local ..." (#7786);
- two members of one protected type with different parameter counts were accepted by the checker and then failed in
  MSIL code generation, while the JVM compiled them (#8104).

## Decision

1. **Bool-required positions reject a bare type parameter** (`typeIsBoolOperand`): `while`, contract clauses
   (T0132), quantifier guards and bodies (T0132), and the operands of `and`/`or`/`xor`/`implies`/`not` (T0034).
   `if` and match-guard conditions already did.
2. **A rigid field read keeps its type parameter.** `rigidTypeParamField` already identified such a field for the
   T0197 member-read check; the field read itself now has that type parameter as its type. It is a `T` like any other,
   so the existing rigid-variable rules apply (T0043, T0060, T0065, T0197). Reads through a concrete or
   under-instantiated receiver keep the erased wildcard, so only the case the checker can decide is tightened. The
   previous reservation (typing the read `T` sent closures over it down the strongly typed path) no longer holds: the
   closure case in `generic_closure_self_test.l` is unchanged.
3. **T0208: explicit type arguments on a constructor.** `name[T](...)` applies explicit type arguments to a generic
   *function*. A record constructor takes its arguments from the expected type (`val b: Box[Long] = Box(value = 5)`,
   which also resolves a phantom parameter). Implementing the index form for constructors would need parser, checker,
   monomorphiser and both backends to agree on a second spelling of what an annotation already says; a precise
   diagnostic is the smaller, correct slice.
4. **T0209: protected members cannot be overloaded.** The MSIL protected-object lowering keys a member by name. Rather
   than make the targets diverge (the JVM accepts the overloads), the checker rejects a second member of one name.
   Supporting overloads on both targets is a possible later extension; it would lift T0209.
5. **`remove` on the stdlib `List`, `Map` and `Set` is `Bool`** (true iff something was removed), as on every backend,
   so a mistyped use is reported (#7978). Statement-position uses are unaffected; a `remove` that is the last
   expression of a `Unit` body now needs `val _ = ...` (three stdlib/ecosystem sites migrated).
6. **MSIL `==`/`!=` on a reified type parameter.** Typing the rigid field read `T` exposed an existing code-generation
   bug: `x == y` where both operands are the enclosing generic record's `T` (a parameter or a field) boxed only the right
   operand, producing invalid IL (`InvalidProgramException`) even for `x == x` with `x: T`, with no field read involved.
   The left operand sits under the right one, so the lowering now spills, boxes and reloads it like an extern struct
   (`isTypeVarMsil`). Covered by `generic_closure_self_test.l` on dotnet and the JVM.

## Not done

- #8018: a *call* of an unknown method on a `T`-typed value (`x.zork()`, `b.v.zork()` under `where T: Named`) is still
  not diagnosed; the call path resolves bound methods leniently. Closing it needs the interface members of each `where`
  bound (`Scope.bounds`) plus the universal methods. The field-style read (`x.zork`) is T0197.
- #7809, #7804 item 2, #7204: element types of non-single-parameter `extern type`s and `String` members need the
  backend's host metadata; the checker is target-agnostic. Plan on the issues.
- #8257, #8100 (protected default arguments, T0161 comparison), #7777 JVM J008: see the issues.
