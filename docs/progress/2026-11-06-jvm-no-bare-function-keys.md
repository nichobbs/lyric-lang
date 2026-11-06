# The JVM registers no bare key for a plain function (docs/70 phase 2d, D336 item 8)

A call binds by the checker's site, the package-scoped key or the qualified key
(`resolveGeneralFuncSig`), so `collectFileSigsSeeded` no longer registers
`name` and `name@arity` for a plain function. `closureInvokeRetType` and
`funcSigRetType` (a spawned call's result type) read the signature through
`resolveGeneralFuncSig` instead of the bare keys. A dot-named function keeps its
bare dotted key for the member-call lookups. Verified with the JVM self-tests
(bitwise, aspect-weave, async-spawn, block-shadow), `emitter_project_self_test.l`,
`examples/agent/tests.l`, the JVM ecosystem suites and the multi-package examples.
