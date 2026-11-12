# TIR builder: members of generic records, protected types and impls (D579, #8613)

Docs/70 phase 3a: `PackageBuild.failed` listed every member of a generic owner as "a method of a generic
type" (159 bodies in the linked self-test census). They now build as `TFnDecl`s with the owner's parameters in
scope as the member's leading type parameters (`TParam(member symbol, i)`; `TFnDecl.ownerParamCount` says how many),
and a generic protected type's fields resolve by bare name in its members and appear in its type entry.
Stdlib tests: 1132 -> 1142 of 1240 bodies built, I0003 0; compiler 11183 -> 11304 of 12561, I0003 27 (unchanged).
Small carry-overs (a `FnBuildFailure.path` field, an `entryFns` guard, a shadowed-protected-field test) ride along. Phase 3a is not complete: I0002/I0003 do not stop the build yet, and a call of a method of a generic type must
still instantiate the owner's parameters from the receiver (the call builder's side).
