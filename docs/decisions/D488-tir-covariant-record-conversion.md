# D488 - A generic record value used at other type arguments is rebuilt field by field (docs/70 phase 3a, #8613)

**Status:** shipped; extends D487.

## Context

D487 rebuilt a union value used at other type arguments as a `match` over its cases. A generic record (`Box[English]` where a `Box[Greeter]` is wanted, `Pair[A, B]`) has one shape and no cases, so the union rule returned None and the conversion stayed counted.

## Decision

`retypeValue` falls through to `retypeRecord` for a type that has no cases: the value is bound once to a fresh local (`TsLet` in an `XBlock`), and the record is constructed again at the arguments of the target type (`XConstruct`), each field read from the local (`XField`) and converted to its type there. The field types are the record's declared ones under its own parameters, read the way the declaration assembly reads them (`fieldsOfRecord`, `tyConvBind`), so the rule needs no side table. It uses existing node kinds only.

A record with a `var` field has identity (D157): a rebuilt copy would no longer alias the original, so it is refused and stays counted. The `BuildEnv.retyping` guard of D487 covers a record that holds itself.

## Results

`tir-builder-shapes-e2e.sh` gains `covariant_record_values` (argument and annotated binding, built with `--verify-ir`, exits 17) and `covariant_recursive_union_stays_counted`, the regression test for D487's guard: a recursive union conversion builds under a timeout with the verifier reporting nothing, and the body stays counted.

Still open: a collection of covariant values (`List[Result[English, String]]`), a recursive union or record (`Tree[T]`), and a union nested in the same union (`Result[Result[English, E], E]`), which the guard refuses.
