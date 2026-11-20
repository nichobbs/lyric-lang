# D408 - A generic record built where the checker left its arguments open takes its fields from the type the node settled at (docs/70 phase 3a, #8613)

**Status:** shipped; extends D429 (the same for a union case).

## Context

`dictForEachEntry(m, { k, v -> result.add(MapEntry(key = k, value = v)) })` in a generic function: the lambda's parameter types come from a generic callee's callback type, which the checker erased, so the record construction's type arguments are open and the checker recorded no constructor signature for it. The builder counted the body ("a method, constructor or member call", I0002): `Std.Collections::mapEntries` on both targets, and any user function with the same shape.

## Decision

When the construction of a generic record has a callee but no recorded signature, and the type its node settled at (the parameter of `add`, here) names the same record with its arguments, the builder builds it from the record's declaration: the call's arguments (named, in field order, or positional) are converted to each field's type at the settled type's arguments, as D429 does for a union case. A call with arguments missing, or out of field order, stays counted.

## Results

`settled_record_ctor` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 1); the stdlib's `mapEntries` builds on the JVM.
