# The JVM resolves a call by its site or an exact key first (docs/70 phase 2d, D336 item 8)

`resolveGeneralFuncSig` looks a call up by the checker's site, the
package-scoped key or the qualified key before it searches the bundle for a bare
name; only a call with no site (an aspect-library template spliced into the
caller, a weaver-synthesised call) reaches the bare-name fallback. Mono's
renamed callee keeps the path's span so a specialised generic's call finds its
site on both backends, specialisations and weaver-synthesised functions register
the package-scoped keys, and the `println`/collection-intrinsic override check
uses the exact stage alone. The fallback and the bare keys go with phase 3b
(tracked on #8612). See D336 item 8; verified by `emitter_project_self_test.l`
and the `lyric-compiler/jvm/` self-test set.
