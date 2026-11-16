# D492 - A field read through an instance at the enclosing generic's own parameters keeps its declared type (docs/70 phase 3a, #8613)

**Status:** shipped; refines D274 item 6.

## Context

Inside a function generic over `T`, reading `box.items` where `box: Box[T]` and `items: List[T]` gave the checker's `fieldsOfRecordInstantiated` result with every type parameter erased, so the read was typed `List[?]`-shaped and a `for` loop over it bound its variable at the erased type. The builder cannot take an erased type (TIR has no wildcard), so every such body stayed counted: the stdlib and ecosystem generic containers, the largest remaining group of "a member access that is not a record field" and "a name that is not a local" sites. D274 item 6 had reserved this erasure because MSIL `==` on a reified `T` was miscompiled; that bug is fixed, so the reservation no longer holds.

## Decision

`rigidRecordFieldType` (checker, `typechecker_exprs.l`) types a member read whose receiver is a record instantiated at type arguments by substituting those arguments into the field's declared type and erasing only the type parameters that are not the enclosing function's own (`eraseTyParamsExcept(t, sc.genericNames)`). A field that is a bare parameter, a receiver with no type arguments and a function with no type parameters keep the previous result. The `for` loop variable (`typechecker_stmts.l`) binds at the element type with the same exception.

## Results

`tir-builder-shapes-e2e.sh` gains `rigid_nested_field` (a generic function reads a `List[T]` field and loops over it, built with `--verify-ir`, exit 9). The wide census after this change and D485-D491: stdlib 2422 of 2545 bodies built (2332 before), compiler 12858 of 12925 (12753 of 12890), ecosystem 3135 of 3208 (3129 of 3495), 0 I0003 in those three areas. The self-test area is not comparable (536 of 756 builds judged, against 391 before). The effect of this change alone was not measured separately from the earlier slices. The same run found two I0003 in the self-tests area that neither this change nor any generic function is involved in: `cross_package_generics_self_test.l` (`call-arg-type` in a consumer `main`) and `jvm_auto_ffi_bridge_self_test.l` (`call-result-type`, the checker records `Int` for a call resolved to an instance overload returning `Long`). Both are open on #8613.

`scripts/ci/unsigned-specialisation-m0007-test.sh` (the M0007 negative test, #7842) is removed for the same reason: its fixture, `match b.value { case Some(v) -> val s: String = v }` in `asText[T]`, only type-checked generically because the payload read was erased, and is now T0060. A generic whose body checks as written but not once its type arguments are substituted needs a source the checker still accepts; none is known. The M0007 path in `Lyric.Pipeline.recheckUnsignedSpecs` stays covered by `mono_self_test.l` (the declaring package not in scope); an end-to-end negative fixture on dotnet and jvm is open on #8613.
