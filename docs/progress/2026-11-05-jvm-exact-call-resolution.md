# MSIL's name-based callee fallback is deleted; the JVM's is narrowed (docs/70 phase 2d, D336 items 6, 8, 9)

`findBareImportedFqnMsil` is gone and the JVM tries the checker's site, the
package-scoped key and the qualified key before its bundle-wide bare-name
search, which stays only for default expressions (a callee only the declaring
package imports; #8850, regression tests in `emitter_project_self_test.l`).
`Lyric.Stubbable` gives its synthesised items spans of their own.
Phase 3b (weaving before the check) gave the weaver's and the aspect templates'
calls sites; Mono's renamed callee keeps the path's span so a specialised
generic's call finds its site on both backends; the MSIL bridge no longer
prefixes the origin-keyed entries of a specialised foreign generic a second
time; specialisations and weaver-synthesised functions register the
package-scoped keys on the JVM. A census (every `TEST_EMITTER_FILES` self-test
and 24 ecosystem libraries on dotnet; the JVM self-tests and five libraries on
the JVM) found the fallbacks used by no call. The JVM's bare keys stay
registered for the secondary readers listed on #8612. See D336 items 6, 8, 9;
verified by `emitter_project_self_test.l` and the `lyric-ui` tests.
