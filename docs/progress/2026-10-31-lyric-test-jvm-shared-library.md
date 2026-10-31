# `lyric test --target jvm` links the library once per run (#8667)

The shared library build of #8648/#8663 covered `--target dotnet` only: a
JVM test run compiled every `[project.packages]` package, and every path
dependency's package, into each entry's bundle. It now builds them once, into
`.lyric-test/LyricTestLibrary.jar`, and links each entry that does not merge
into a library package against that JAR as a restored dependency, the path a
published Lyric JAR already takes (#3094): the JAR carries a
`Lyric.Contract.<Pkg>` resource for each of the library's own packages
(#4994), never for the standard library packages it bundles.

The entry's JAR holds only its own packages and the standard library closure
it uses, so a linked entry runs with
`java -cp <entry.jar>:<LyricTestLibrary.jar> <main class>` (after the
`[maven]` classpath when there is one); the entry's JAR comes first, so a
class both JARs bundle (the standard library's, compiled from the same
source) resolves to the entry's.

As on dotnet (#8687), the linked attempt is compiled with its diagnostics
collected and is the only check: an entry it cannot build is compiled with
the library as before, after a `note:` naming the first error. That needed
the JVM half of the collect mode:

- `Jvm.Bridge.compileProjectToJarBundledWithRestored` takes a `DiagSink` and
  passes it to `jvmProjectFrontEnd` (which already took one, for
  `checkProjectTypesJvm`), to `runMiddleEnd` (its `MiddleEndOptions.sink`;
  `Lyric.Pipeline.pipeMiddleEnd` now hands it to `pipeWeave`), and to the
  build's own J002 and J003 reports (`jvmBuildReport`).
- `Lyric.Emitter.emitProjectCollecting` accepts `--target jvm`; a contained
  JVM codegen panic is collected (`jvmBridgePanicDiagnosticQuiet`).

Linking real libraries found two JVM restored-package gaps, each also a gap
for any consumer of a published Lyric JAR. Both failed only at run time, with
`NoSuchMethodError` or `NoClassDefFoundError`:

- A restored package's own imports did not reach its signatures. The
  synthesised source keeps no imports; the contract's are recorded in
  `pkgImportNames`, but `transitiveWantedPkgs` started from `file.imports`
  only, and `externSeedForFileCached` keyed its cache on them, so every
  restored package shared the seed of whichever was computed first. A bare
  imported type in a restored signature then resolved to the restored package
  itself: `Web.withSpec(router, spec: Spec)` named `Web/Spec` instead of
  `Web/OpenApi/Spec`, and the generator SDK's plugin codecs returned
  `Lyric/GeneratorSdk/JsonValue` instead of `Std/JsonValue/JsonValue`. The
  closure now also starts from the package's recorded imports, and the cache
  key includes them.
- A restored `impl I for R {}` is head-only, so a method called on a value of
  the concrete record type had no signature and was emitted with an `Object`
  return (lyric-i18n's `InProcessTranslationStore.translate`, lyric-mcp's
  `PipedNdjsonTransport.close` from `Std.JsonRpc`'s transport interface).
  `registerHeadOnlyImplsJvm` now registers each of I's methods on R, after
  every restored package is collected: from I's declaration when R's package
  declares it, otherwise by copying the methods registered under I's class.
  It is not gated on `implIfaceExternDottedFqn`, which also reports another
  package's Lyric interface as extern. `Msil.Codegen.registerRestoredImpl`
  (#1602) did the same for an interface of R's own package only; it now
  finds one another restored package declares too.

`withLibraryTemplates` no longer adds a library package that is already a
template source: on the JVM the library packages include the path
dependencies' packages, which are.

`scripts/ci/test-runner-project-mode-e2e.sh`'s JVM case now runs the whole
fixture on `--target jvm` and checks the library JAR is built once, linked by
every entry it can serve (unions, generic records, enums in library records,
a distinct type, a record invariant, a library signature naming another
library package's type, impls of an interface of the record's own package and
of another library package's, called on the record), with the two non-literal
`pub val` entries compiled with the library after a note and no discarded
errors in the output.  The 15 suites of `scripts/ci/jvm-ecosystem-suites.sh`
all pass linked; 4 entries fall back, each on a compile-time gap of the
restored path (a non-literal `pub val`, #6133, or a reference only the full
compile resolves).
