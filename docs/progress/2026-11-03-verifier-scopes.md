# TIR verifier follow-ups: scopes, record-pattern checks, function-level diagnostics (#8613)

D332.

- `Lyric.Tir.Verify` tracks scopes (`local-in-scope`), checks record-pattern
  fields (`field-exists`) and constructor patterns on signature-less cases
  (`pattern-callable`), and names the function in every diagnostic.
- Tests: six new cases in `tir_verify_self_test.l` (22 total); one in
  `resolve_self_test.l`.
