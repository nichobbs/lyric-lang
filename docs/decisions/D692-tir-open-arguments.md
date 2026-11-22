# Arguments the checker left open take their parameter's type through a function value and inside a tuple (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`f(None)` and `g(Ok(value = 3))` where `f` and `g` are local function values, and `Held((None, 6))` (a union case whose payload is a tuple holding `None`), left the argument without a type the builder could use: the checker types a bare `None` with a hole and the argument's own context fixes it. A direct call settled its arguments to the parameter types, but a call through a function value did not, and settling stopped at the top node of a tuple argument (`expected_type_inference_self_test.l`, `tuple_expected_type_self_test.l`).

## Decision

A call through a function value settles each argument the checker recorded no type for, and whose form fixes its type from its position (a bare name, a bracket literal, a tuple, a construction named by a path, any of them in parentheses), to the function type's parameter. A host call keeps the type of its host result and is converted, as before. `settleArg` settles recursively (`settleHole`), so the elements of a tuple argument take the tuple's element types.

## Results

`tir-builder-shapes-e2e.sh` (`open_arguments`); `expected_type_inference_self_test.l` and `tuple_expected_type_self_test.l` build under the gate.
