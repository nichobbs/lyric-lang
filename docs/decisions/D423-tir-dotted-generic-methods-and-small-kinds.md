# D423 - Dot-named generic method calls, zero-filled array fields, impl sibling calls, folded range bounds and shared enum cases build (docs/70 phase 3a, #8613)

**Status:** shipped; extends D173 (value-generic records' methods), D167 (array zero values), D389 (method call sites), D580 (members of generic types).

## Context

Five kinds of body were still counted after D457-D459, each from the wide census:

- **A method of a value-generic record called on a receiver** (`self.left.sum()`, a bare `viaField()`, `v.sum()` in a generic or concrete caller; also `Option.orDefault` and any dot-named generic function called with method syntax). The methods of a value-generic record are dot-named generic functions (D173). The checker recorded a method call site only for a function that is not generic and whose receiver has no type arguments, so the call had a callee and no signature.
- **A construction that leaves out an array field** (`Ints()` with `N` fixed by the expected type, `Plain()` over `array[3, Int]`): the field's zero value (D167) is recorded as an argument expression the typed IR cannot build, and the parameter has no default, so the argument was counted missing or defaulted.
- **A bare call of a sibling method in a generic `impl`** (`pickSelf(false, other)` inside `impl[T] Mergeable for Box[T]`): the member's key is `Pkg::Box[T]::$impl(I)::name`, which the test for "declared in the type's body" (the type's key then `::`) does not match.
- **A range pattern bounded by a named constant** (`case 1 ..= HighBound`): `TpRange` carries literals, and only a literal was accepted.
- **A case name two enums of a package share, read through the package** (`val b: Lib.Beam = Lib.On`): the checker typed the node against the expected type and recorded no reference, so the builder had no case to name.

## Decision

- The checker records a dot-named function that is generic, or whose receiver is an instance of a generic type, in `methodCallByNode` with its full signature (`MethodCallSite.full`). The builder instantiates it as a call of that function with the receiver first: the function's generics are read off the receiver's type and the arguments (`genericArgsFromCall` takes the receiver as a leading argument), the receiver is converted to the substituted first parameter, and the callee is `Direct(sym, typeArgs)`.
- An omitted array field takes `XZeroValue` at the parameter's type when the checker recorded its zero for the construction (`arrayCtorZeroArgs`).
- A call of a member of the same `impl` as the member being built (same DefPath owner) is an owner-generic call when the impl's target is written over exactly the impl's own parameters, in the order it declares them, so the receiver's type arguments are the impl's position by position; any other impl keeps its count.
- A range pattern bound that is an integer constant expression the checker folds (`tryFoldInt`) is the folded literal.
- `inferExprExpected` records the reference when an expected type settles a shared case name (`recordQualifiedEnumCaseRef`), as the bare-name read already did in the builder.

## Results

`value_generic_record_self_test.l` builds 19 of 20 bodies (was 14), `impl_generic_target_self_test.l` and `unsigned_typed_ops_self_test.l` build every body, and `tir_build_self_test.l` has a case for each of the first four, `tir-builder-shapes-e2e.sh` a project shape for the fifth. All with no I0003.

Still counted, with their causes: a union case built inside a lambda whose parameter type the checker erased (`{ m -> App(msg = m) }` against `(M) -> Wrap[M]` in a generic function: the checker's recorded result is `Wrap[<error>]`, so the builder must instantiate the case's fields from its own `Ty`), a nullary case of a value-generic union (`Shape.Empty` at `Shape[N]`), and an import-alias qualified function value (`AL.update`).
