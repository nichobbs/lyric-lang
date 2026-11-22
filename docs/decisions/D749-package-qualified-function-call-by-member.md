# `Pkg.f(x)` written as a member of the package's name resolves to that package's function (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`Lyric.ErasedReceiverJvmSelfTest.qualifiedFailure()`, a call qualified by the file's own package (#8634): the callee is a member chain, and `findDirectSigPick` resolved a member callee only as a method, a dot-named function of a type or an extern package member. The call had no signature, so its type was a hole and the typed IR could not build it (`erased_receiver_jvm_self_test.l`).

## Decision

A member callee whose receiver is a dotted name that no local, parameter or field binds, and that some candidate of the callee's name declares itself (`originPackage`), resolves to that package's function, exactly as the same call written as a path does (`packageQualifiedFuncSig`).

## Results

`erased_receiver_jvm_self_test.l` 7 of 7 on the JVM.
