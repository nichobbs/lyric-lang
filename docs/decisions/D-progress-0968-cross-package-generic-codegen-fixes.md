# D-progress-968 — Generic inference and MSIL fixes found by a cross-package UI example

**Status:** shipped

## Problem

`examples/ui-customers` (a screen built on the generic `lyric-ui` and
`lyric-forms` libraries) compiled but failed 11 of 14 tests with
`InvalidProgramException` and `ArrayTypeMismatchException`; `ilverify`
reported invalid IL in both libraries and the example. The causes were
independent:

1. **Collection expectation leaking into statements (MSIL).** A function's
   declared return type sets the construction expectation for its trailing
   value, but it stayed in force for the statements before it: `for t in
   [Tier.A, Tier.B]` inside a function returning `List[String]` built a
   `List<string>` of enum values.
2. **Qualified calls into another package.** `Pkg.span(0, 1_000_000)` passed
   `int32` to a `Long` parameter: codegen widens an argument only when it has
   the callee's parameter types, which a restored package's call site lacks.
   And `Lyric.Mono` could not see another package's non-generic signatures,
   so `Pkg.collect(errs, Pkg.longOr(s), 0)` specialised `collect` at the
   literal's `Int` instead of `Long`.
3. **Generic inference with a widening literal (checker).** The same call
   bound `T` to `Long` (from the `Result`) and `Int` (from the literal); the
   conflict produced an error type that silently accepted any use of the
   result, so `val s: String = collect(...)` type-checked.
4. **Calls through a function-typed union case field (MSIL).** `case
   OnInput(f) -> f(data)` returned `object` rather than the field's declared
   return type, so an `Int` instantiation returned a pointer's bits.
5. **Function values held as `object` (MSIL).** An unannotated `val g = { ...
   }` passed to a function-typed parameter or record field reached a
   `Func`/`Action` slot as `object`.
6. **Async builders over in-bundle types (MSIL).** The
   `AsyncTaskMethodBuilder<T>`, `Task<T>` and awaiter TypeSpecs were encoded
   during codegen, before the bundle's TypeDef rows are known, so
   `Option<Msg>` became `Option<object>` in every member reference while the
   builder field kept `Option<Msg>`.
7. **Annotated locals in specialised generics (`Lyric.Mono`).** `val input:
   View[Msg] = textInput(v, onInput)` inside a generic imported from another
   package took the ORIGINAL call's inferred type (`View[Object]`: the lambda
   argument's return type is unknown in a foreign body) over the annotation,
   so `field(..., input)` specialised as `field__Object` and a later match
   took the wrong arm.

## Decision

1. `lowerStmtsExprFromMsil` clears the collection expectation across the
   non-tail statements of a value block, as it already did the construction
   hint.
2. The checker records (a) the widened arguments of a direct call to another
   package's function in `argConversionSites`, lowered by the existing
   D-progress-963 desugar on every target, and (b) the result type of every
   qualified and method call in `SymbolTable.callResultTypes`, which
   `Lyric.Mono` consults only when its own inference finds nothing.
3. `inferOneGenericArg` accepts numeric widening: when two bindings of `T`
   differ and the narrower comes from a bare `T` parameter (an argument that
   widens at the call), `T` binds to the wider type. Any other disagreement
   is still unresolved. A negated literal (`-1`) now adopts the other
   operand's integer type the way `1` already did (#2514), so
   `someLong == -1` type-checks. It never adopts a type with no negative
   values (`Byte`, `UInt`, `ULong`, `Nat`): `someUInt == -1` stays an error.
4. Union case fields register their function return types like record
   fields, in-bundle and restored; a constructor pattern binding such a field
   records the return type (substituted with the scrutinee's type arguments)
   for the bound name.
5. `castObjectToDelegateMsil` narrows an `object` argument or constructor
   field value to a `Func` parameter or field type. `Action` targets are not
   cast: a Unit-returning lambda is built as a `Func<..., object>`, so the
   value in an `Action`-typed slot is not an `Action` (#7219 tracks aligning
   the two; until then an `object` stored into an `Action` slot remains an
   `ilverify` finding, as in `lyric-ui`'s `Ui.Host.instance`).
6. `ctxAddGenericInstTypeSpec` registers a codegen-time GENERICINST TypeSpec
   and records it; `discoverTypeDefRowsInto` re-encodes each once the
   bundle's TypeDef rows are known. Every codegen-time builder, task and
   awaiter TypeSpec uses it.
7. `rewriteBinding` hands `bindingEnvTE` the rewritten initializer, whose
   callee names the specialisation actually chosen (#5604's rationale: the
   value's instantiation is decided by the callee's specialisation).

## Verification

- `list_literal_index_self_test.l` (for-loop literal, both targets),
  `record_function_field_self_test.l` (union function field, including an
  `Int` instantiation, both targets), `cross_package_generics_self_test.l`
  (qualified widening and restored-result inference; annotated local in a
  three-package specialised generic), `result_generic_specialization_self_test.l`
  (a same-package generic specialised at `Long` from a widening `Int`
  literal, both targets).
- `examples/ui-customers`: 14/14 tests. `ilverify` is clean on `lyric-forms`;
  on `lyric-ui` and the example its only findings are the #7219 `Action`
  stores in `Ui.Host.instance` and its specialisation.
- The CI self-test list (254 entries) passes except the known
  environment-only `auto_ffi_jvm` and `jvm_auto_ffi_bridge` cases.
