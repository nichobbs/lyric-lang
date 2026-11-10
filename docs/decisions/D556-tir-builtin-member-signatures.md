# D556 - A built-in member call takes its parameter types from the checker's function type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D362 and D367.

## Context

The builder converts a built-in call's arguments to the parameter types of its signature, but it
derived those only for the collection and slice members it had a table for (`memberArgTys`). Any
other built-in given an argument an implicit widening could change was counted as `a built-in call
with an argument the builder cannot check` (27 over the stdlib census after D554), though the checker
had already typed the member: `String.substring`, `replace`, `startsWith` and the rest of the
`String` surface have real `TyFunction` types (`stringHostMethodType`), and the integer bitwise
methods (`and`, `or`, `xor`, `shl`, `shr`) have a known argument type.

## Decision

The checker records the function type of a built-in member call's callee under the call's `NodeId`
(`SymbolTable.builtinFnTyByNode`, filled by `recordBuiltinFnTy` where `recordBuiltinCallee` already
names the built-in, and for the bitwise methods at their own site, with the argument the checker
checked against: the receiver's type, or `Int` for a shift count). When the builder has no table of
its own for a built-in member, it takes the parameters from that type and converts the call's
leading arguments to them (a call that leaves an optional trailing argument out supplies fewer than
the type has parameters). An argument the types derive no conversion for is still counted. The
tables for collection and slice members stay as they were.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, after D554: bodies built 992 -> 1006 of 1165, I0003
0, `a built-in call with an argument the builder cannot check` 27 -> 0.
