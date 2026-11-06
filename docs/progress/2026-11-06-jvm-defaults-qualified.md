# The JVM's last bare-name callee search is deleted: defaults are qualified where their package is checked (docs/70 phase 2d, D336 item 8, #8850)

A parameter or field default is lowered in the package that calls the function
or builds the record, but its callees are the declaring package's, so the JVM
kept a bundle-wide bare-name search for them. `Lyric.Pipeline.pipeCheckedDefaults`
now writes each bare call of a default as the callee's package-qualified path
from the checker's sites (`qualifyCheckedCallees`), and `resolveGeneralFuncSig`
is the exact stage alone. `Expand.respanGenerated` also gives a generated
callee path a span of its own, because the checker keys a call's site by the
callee path's span: `Lyric.Stubbable`'s synthesised `makeStubCounter()` default
had lost its site to the next call generated for the same interface method.
Verified by `emitter_project_self_test.l`'s default-expression cases on both
targets, `examples/agent/tests.l` on the JVM, the JVM ecosystem suites, the
multi-package and single-file examples and the plugin suites.
