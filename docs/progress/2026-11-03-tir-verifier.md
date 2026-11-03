# `Lyric.Tir.Verify`: the TIR verifier, docs/70 phase 3a step 2 (#8613)

D323.

- **`Lyric.Tir.Verify`** (new, `lyric-compiler/lyric/tir/verify/`):
  `verifyPackage`, `VerifyDiag`, `renderVerifyDiag`; I0003 with the rules of
  docs/70 §6.4 (closed types, call arguments equal to the callee's parameters
  under the instantiation, symbols and locals defined, branch types, mutable
  assignment, unique NodeIds, closure captures).
- `Lyric.Pipeline.pipeVerifyTir` is the entry point passes call.
- Tests: `tir_verify_self_test.l` (well-formed accepted, each rule fires on the
  broken node).
- Next in 3a: `NodeId`s on the parser's nodes, then the §5 type rules.
