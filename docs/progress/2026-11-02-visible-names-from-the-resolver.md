# What a bare name can mean comes from `Lyric.Resolve`, docs/70 phase 2c step 5 (#8612)

D315.

- `Lyric.Resolve.visibleDecls`: every declaration of a name a file can reach.
- `symTableTryFindAllVisible` answers from it for the checked package;
  `symTableTryFindAll` became `symTableTryFindAllNamed`, kept for callers that
  narrow by a qualifier, an owner id or a declaring package.
- Differential mode compares the sets (`R0002`); `scripts/ci/resolve-diff.sh`
  greps `R0001` and `R0002` and reports covered projects (#8720).
- Tests: two `resolve_self_test.l` cases for `visibleDecls`.
- Next: dependency scopes in the resolver, then delete the scan, the hidden
  hint and the sibling-file rules; fold in the alias passes.
