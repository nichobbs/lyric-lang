# D487 - A union value used at other type arguments is rebuilt case by case, with each payload converted (docs/70 phase 3a, #8613)

**Status:** shipped; extends D483.

## Context

A `Result[English, String]` is accepted where a `Result[Greeter, String]` is wanted when `English` implements `Greeter` (covariant conversion, language reference 2.11). D483 rebuilt a union-case *construction* at the other instantiation (`retypeConstruct`), but a value that is not a construction (a call result such as `okEnglish(n)`, a local) had no case: the builder counted a branch, argument or annotated-binding conversion, about 50 sites in the self-test census.

## Decision

`convertValue` falls back to `retypeValue`: when the two types are one union at different type arguments, the value becomes a `match` over every case of the union (`caseSymbolsByParent`) whose arm binds the payload to fresh locals and constructs the same case at the target arguments, each payload converted to its type there (`convertValue` again, so an upcast becomes `CvUpcast`). It uses `XMatch`, `TpCtor`, `XConstruct` and `XLocal` only, so no model, verifier, interface or backend change. The `match` is exhaustive by construction.

A union already being rebuilt up the stack is refused (`BuildEnv.retyping`): a recursive payload (`Tree[T]`) would need an unbounded match, and it stays counted. A first version without the guard hung the build on `covariant_conversion_self_test.l`.

## Results

`tir-builder-shapes-e2e.sh` gains `covariant_union_values` (argument, tail expression and annotated binding; builds with `--verify-ir`, 0 I0003, exits 30). `covariant_conversion_self_test.l` builds 24 of 28 bodies. Still open: a recursive union (`Tree`), a generic record at other arguments (`Box[English]` as `Box[Greeter]`, `Pair`), and a collection of them (`List[Result[English, String]]`).
