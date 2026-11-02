# The single lookup and T0219 come from `Lyric.Resolve`, docs/70 phase 2c step 7 (#8612)

D318.

- `symTableTryFindOne` walks the package's file scopes nearest first; the
  checker's scan serves dependency signature scopes only.
- T0219, the extension tier and the alias readers use the resolver's per-file
  scopes (`bareVia`, `externVia`, `qualifiedVia`, `FileScope.directPkgs`).
- The resolver gets the same dependency items the checker registers.
- Deleted: the per-file rule tables, the import-visibility maps, the
  differential mode and `scripts/ci/resolve-diff.sh`.
- Next: dependency scopes in the resolver, then the alias passes.
