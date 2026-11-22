# `List.set` and `Map.set` are typed members of the stdlib collections (docs/70 phase 3a, #8613)

**Status:** shipped; checker (result, parameters and callee) and builder (the built-in's parameter types).

## Context

docs/01 section 2.7 lists `.set` among the members of `List` and `Map`, but the checker typed no result and no parameters for it, so `xs.set(0, 999)` left an untyped call and the TIR gate (D347) stopped the body (`llvm_stdlib_self_test.l`, the `toArray` snapshot program).

## Decision

`List.set(index, element)` and `Map.set(key, value)` are `Unit`, with the parameter types `add` has (`Int` and the element; the key and the value), checked as `add`'s are (T0042, T0043). The call is recorded as the built-in `List.set` or `Map.set`, and the builder gives the built-in the same parameter types. Their lowering is unchanged: a target that cannot lower the member still reports it from its own code generator.

## Results

The `toArray` snapshot program of `llvm_stdlib_self_test.l` builds under the gate on native.
