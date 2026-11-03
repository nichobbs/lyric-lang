# D334 - The polymorphic builtins have generic signatures (docs/70 phase 3a, #8613)

**Status:** shipped. The "polymorphic builtins get real signatures" rule of
docs/70 §5.3, after the rigid `TyParam` of D331 (D329/#8745).

## Context

`println`, `print`, `toString` and `format1`-`format4` were typed with `TyError`
parameters: `codegenBuiltinType` returned `TyFunction([TyError], ...)`, so any
argument satisfied the parameter because `TyError` is a hole, not because the
signature said so. docs/70 §5.3 replaces the hole with a generic signature.

## Decision

1. `println[T](x: T): Unit`, `print[T](x: T): Unit`, `toString[T](x: T): String`
   and `formatN[A1..AN](template: String, a1: A1, ..., aN: AN): String` are typed
   with type parameters (`TyParam`) instead of `TyError`. The parameters share the
   reserved owner `"$builtin"` (`builtinParamOwner`): a builtin has no declaration
   to own them.
2. A call to a builtin instantiates its signature at the call
   (`instantiateBuiltinCall`): each `$builtin` parameter is bound to the type of
   the argument in that position, before the arguments are compared with the
   parameters, as for any generic call. Arity (T0042) and the `String` template
   (T0043) are checked as before; nothing a program may write is newly accepted
   or rejected.
3. `panic`, `expect`, `assert` already had concrete signatures. `default()` keeps
   `TyError` as its result: its type is the expected type, which is inference
   (T0210, owned by the type-rules work), not a signature.
4. **Census.** A builtin used as a value (not called) would now carry a rigid
   parameter. The sources were searched for `println`, `print`, `toString` and
   `format1`-`format4` outside a call: the only hits are a local variable named
   `println` in a JVM self-test, which shadows the builtin. No source needs
   migrating, so this is a single step.

## Consequences

The checker's own signature table no longer contains a `TyError` parameter for a
builtin, which removes that class from the I0001 gate's census (docs/70 §5.3).
`typechecker_self_test.l` gains four cases: any argument type accepted,
`toString` is a `String` and `println` a `Unit`, arity still checked, `formatN`
template and arguments.
