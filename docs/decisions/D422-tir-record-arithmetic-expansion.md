# D422 - A derived record operator builds as its fields' operator in a record built from them (docs/70 phase 3a, #8613)

**Status:** shipped; extends D155 (component-wise `Add`/`Sub` on homogeneous numeric records).

## Context

`a + b` on a record that derives `Add` or `Sub` applies the operator field by field and evaluates each operand once (D155). The checker records each such operator by its span (`recordArithSites`) and `Lyric.ContractElaborator.lowerRecordArith` rewrites the source into a block that binds both operands and builds the result record from the fields' sums. TIR has no node for it, and the builder runs on the checked tree before that rewrite, so every body holding one was counted ("record arithmetic").

## Decision

TIR gets no new node. The builder expands the operator as the language states it, in the typed IR: an `XBlock` that binds the left and right operands to two locals, then an `XConstruct` of the record whose fields are the intrinsic operator applied to the two operands' fields (`XField` of each local). The record's declared fields give the order and types, and the expansion is counted when a field is not a primitive or the record is generic (D155 rejects both). A compound `r += s` builds as `r = r + s`: the statement's target is the left operand and its place, the operator comes from the recorded site.

A derive-generated function was not chosen: the derive produces no function in the checked tree, so a call would name a symbol the package does not declare, and every backend would then need that function too. The expansion is the same shape `lowerRecordArith` builds, so a backend lowering TIR does exactly what the AST lowering does today.

## Results

`record_arith_self_test.l` builds every body (`midpoint` and the operator tests); a new `tir_build_self_test.l` case covers `+`, `-` and `+=` and verifies the built bodies.
