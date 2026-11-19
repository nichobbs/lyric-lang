# D426 - A list literal where a List is wanted, and a built-in member's argument settled by its parameter (docs/70 phase 3a, #8613)

**Status:** shipped; extends D495 (a list literal typed as a slice and used as a fixed array).

## Context

The checker types a bracket literal passed to a generic record's `List[T]` field (`GBox(items = [x, x])`) or to a `Map[String, List[String]]`'s `add` as a slice, and accepts it there: a literal builds the `List` the context wants. The builder converted the argument to the parameter's type and had no conversion from a slice to a `List`, so the body was counted ("an argument conversion", I0002). A second argument of that call, `newList()` for the map's value, was typed with a hole the call's other arguments do not fix, and a built-in member's arguments were built before their parameter types were known.

## Decision

`retypeListLiteral` also builds a literal at a `List[T]` host type: the same elements, each converted to `T`, at the `List` type, as an annotated binding's literal is. A built-in member's arguments are built after the receiver and settled against the member's parameter types when the receiver's type fixes them (`memberArgTys`), as a construction's and a call's are, so `newList()` takes the map's value type.

## Results

`LiteralArgShapeSelfTest::boxOf` and `EnumCaseCollisionSelfTest::guardNativeImports` build; the new `list_literal_arguments` shape in `scripts/ci/tir-builder-shapes-e2e.sh` builds both with the verifier clean and runs the program.
