# The JVM resolves a call by its site or an exact key, never a bare name (docs/70 phase 2d, D336 item 8)

`resolveGeneralFuncSig` no longer searches the bundle for a bare name: a call
binds by the checker's site, the package-scoped key or the qualified key. Mono's
renamed callee keeps the path's span so a specialised generic's call finds its
site on both backends, specialisations and weaver-synthesised functions register
the package-scoped keys, and the `println`/collection-intrinsic override check
uses the same exact stage. The bare keys stay registered for the remaining
secondary readers (tracked on #8612). See D336 item 8; verified by
`emitter_project_self_test.l` and the `lyric-compiler/jvm/` self-test set.
