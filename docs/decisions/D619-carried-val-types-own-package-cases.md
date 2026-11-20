# D619 - A `val` of another package takes the type its interface recorded, a package's own case name is its own, and a generic record's field read is typed (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, plus two annotations in `lyric-validation`.

## Context

- `pub val answer = helper() + 1` in one package and `toString(answer)` in another: the reader's checker cannot type an unannotated `pub val` whose initialiser needs the declaring package's scope, so it records no type for the read, and the body was counted unbuilt (I0002). The declaring package's interface records the type (D327 item 9, #7777).
- `match Green { ... }` in a package that declares `enum Color { Green }` while another package of the program declares `enum Signal { Green }`: the checker finds two cases of the name, records neither a type nor a reference for the bare name, and 58 bodies of `jvm_cross_package_collision_self_test.l` were counted unbuilt. A package sees its own declarations first (docs/70 4.3).
- `lyric-validation`'s `combine` and `all` bound `val acc = Collections.newList()` and added to it: the element type is inferred from later use, which the checker leaves open (docs/01 2.11 asks a library to annotate such a local).

- `val f = p.step` where `p: Prog[M]` and `step: (M, Int) -> M`: the checker records no type for a read of a field declared at a type that mentions the record's parameters.

## Decision

`openRefValueTy` types a read of a `val` or `const` of another package that the checker left untyped from the interface that package carried to the build (`readCarriedValueTy`, the same store D482 reads defaults from). `openBareOwnCaseTy` types a bare payload-free case name, no local and no recorded reference, as the one non-generic type of the package being built that declares a case of that name, when exactly one does; the case is then built as `sharedCaseRead` builds a shared name. The same case name as a `match` pattern is the case of the scrutinee's own enum (`buildPat`). A read of a `val` of another package the checker recorded no reference for is a module value named by its DefPath (`buildBareForeignValRead`), and an arithmetic operator whose operands the checker could not type takes its left operand's integer type. `openGenericFieldReadTy` types a field read of a generic record at the field's declared type under the receiver's arguments. `combine` and `all` annotate their accumulators as `List[ValidationError]`. No program changes meaning: the checker accepts what it accepted.

## Results

`jvm_cross_package_collision_self_test.l` builds the `Col.A` and `Col.Z` bodies (58 of them across the self-test's builds); `lyric-validation` builds all its bodies; the cross-package `val` fixtures (`XVal7777`, `MultiSegVal`, `SelfQual`, `Main7777`, `EarlyRead`) and `Reg.Gen::apply` are the cases these rules are for, and the self-test census records which of them build.
