# D456 - A call through a record's function-typed field has a recorded callee type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D360 (the per-node expression types).

## Context

`p.classify(x)`, where `classify` is a record's function-typed field, is an indirect call the builder builds by building the callee `p.classify` as a value. The checker typed the callee through the field surface (`inferMemberBase`) and never recorded a type for the member expression, so the builder reported "the checker recorded no type for expression node". Inside a generic function over a generic record (`f[E, M](p: P[E, M], x: E)`), `inferMemberBase` goes through `fieldsOfRecordInstantiated`, which erases the record's parameters, so the callee and the call both had an unknown type.

## Decision

When a member callee is a function value, the checker records its type under the callee's node. When the field's instantiated type has an unsolved part, the callee is typed by `fieldTypeKeepingBinders`: the record's fields substituted at the receiver's arguments (`fieldsOfRecordSubstituted`), so the enclosing generic's own parameters stay parameters instead of being erased. Argument and result checking then use `(E) -> M` rather than an unknown type; a call that previously had its argument or result unchecked is now checked against rigid parameters, as every other use of the generic's parameters already is (docs/70 section 5.1).

## Results

`tir_build_self_test.l` builds the call for a non-generic record, a generic record at concrete types and a generic record inside a generic function. The type checker's own self-test (1155 cases) is unchanged.
