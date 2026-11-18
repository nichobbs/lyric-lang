# D452 - An exposed record's construction has a recorded signature (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 (the construction signature in the symbol table).

## Context

The checker records a record construction's fields as a signature under the call's node id (`ctorSigByNode`), so the TIR builder places the arguments by field. It recorded one for a record, an opaque type, a protected type and a union case, but not for an `exposed record`, so every construction of one (`E(value = v)`, generic or not) was counted as "a method, constructor or member call" (I0002): the generic exposed, value-generic and restored-exposed self-tests and the ecosystem programs that use exposed records.

## Decision

`recordCtorSigNode` handles `DKExposedRec` with the same field reading as `DKRecord`, now one helper (`recordCtorParams`) that both arms call. The builder needed no change: `typeEntries` already holds exposed records (`build_syms.l`).

## Results

`tir_build_self_test.l` builds a non-generic and a generic exposed record's construction with 0 I0002 and 0 I0003.
