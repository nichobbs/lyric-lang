# A bare union case must be visible to the file, docs/70 phase 2c step 9 (#8722)

D328.

- `nameIsSharedUnionCase` counts the cases the file can reach
  (`symTableTryFindAllVisible`): a bare case through an alias-only import is
  `T0020`. `regex_tests.l` imports `Std.Regex.{RegexError}`.
- A restored dependency's imports keep their form: `ImportedPackage.selectedImports`
  and `importDeclsFromNames` replace "every name is a whole import" (D322 item 2).
- Tests: reject-corpus case `bare_union_case_alias_only_import`; two
  `typechecker_self_test.l` cases.
- Next: fold `AliasRewriter` and `TypeAliasResolve` into the resolver.
