# D579 - Members of generic records, protected types and impls are TFnDecls over the owner's parameters (docs/70 phase 3a, #8613)

**Status:** shipped; extends D573 and D576.

## Context

D573 built the methods of a record, the members of an `impl` and a protected type's funcs and entries as
`TFnDecl`s, but listed every member of a generic owner in `PackageBuild.failed` as "a method of a generic
type" (159 bodies in the linked self-test census). A generic protected type's fields were also unknown to the
bare-field resolution of D576, which refused a generic owner.

## Decision

- The checker keys a member's generic scope by binder: the owner's parameters under the owner (a type's name,
  or `implOwnerKey`, now `pub`), the member's own under `Owner.fn`. The builder binds the same keys, both to
  the member's symbol: the owner's parameters come first in the member's generic space and its own after, so
  `TParam(memberSym, i)` is the owner's `i`-th parameter for `i < ownerParamCount` and the member's own after
  that. `MemberOwner` (key, owner type symbol, parameter names) lives in `BuildEnv.memberOwner`.
- `TFnDecl.typeParams` is the owner's parameters then the member's own, and the defaulted
  `TFnDecl.ownerParamCount` says how many lead. Nothing in `Lyric.Tir.Verify` changes: the closed-type rule
  already admits `TParam(fnSym, i)` for `i < typeParams.count`, and a call instantiates the owner's
  parameters like any generic call's (owner arguments from the receiver first, then the member's own), which
  is why the leading-parameter model was chosen over `TParam(ownerSym, i)` (it would have needed a second
  substitution rule in the verifier and in every backend).
- The receiver `self` is the owner applied to its own parameters as the member sees them
  (`TNamed(ownerSym, [TParam(memberSym, 0..n)])`), or the converted target type of a generic `impl`; it is
  made when the member is built, once its symbol is known.
- `protectedFieldsOf` no longer skips a generic protected type, and `typeEntries` binds the type's parameters
  while converting its field types and records the parameter count on its type entry.
- Calls of a method of a generic type must instantiate the owner's parameters from the receiver's type
  arguments; `TSig.typeParamCount` is the member's own count. That is the call builder's side, not changed here;
  tracked in #9016.

- Small carry-overs from earlier reviews ride along, all on the declaration side: `FnBuildFailure.path` carries the
  DefPath key of a failed body's symbol (D570 left only the display name); `buildPackage` guards the `entryFns`
  set against a repeated symbol; a test pins that a local named like a protected field is the local (D576). D576
  says its test file has 133 cases; it had 135 (the record is frozen, so the correction is made here).

## Measured

`tir_build_self_test.l` (138 cases): a generic record method (verified, no own parameters, one owner
parameter in scope), a method with its own parameter beside the owner's, a generic protected type's entry and
func over a field typed by the owner's parameter, and a generic `impl` member, each built and verified (I0003
0). `tir-census.sh --wide`, before (D573) and after (bodies built / total): stdlib tests 1132/1240 -> 1142/1240,
I0003 0; compiler 11183/12518 -> 11304/12561, I0003 27 (unchanged, not members); the uncovered kind "a method of
a generic type" no longer appears in any area.
