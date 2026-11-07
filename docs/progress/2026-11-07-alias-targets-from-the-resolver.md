# Alias targets come from the resolver; an alias of a renamed-import type binds its package (#8752)

`Decl` carries an alias's target and `Lyric.Resolve.aliasTargetsFor` answers the
`alias X = T` table a file sees, with renamed-import heads spelled out
(D344). `projectAliasTargets` and `canonicalAliasDotNamed` read it, which fixes
`alias Pick = T.Seed` under `import A.Two as T` binding package One's `Seed` for
`Pick.base()` on both backends. Verified by `resolve_self_test.l` and by
`emitter_project_self_test.l` on MSIL and JVM. The `AliasRewriter` walk,
`TypeAliasResolve` and the backends' alias layers stay until the typed IR
(docs/70 §13 phase 4).
