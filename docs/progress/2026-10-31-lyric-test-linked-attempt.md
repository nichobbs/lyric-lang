# `lyric test`: one compile per linked entry (#8667)

Follow-up to the shared library build (#8648, #8663). A linked entry used to
load and re-type-check the library's restored contracts twice: once in the
`Emitter.typeCheckProject` probe that decided whether to link, and again in
`Emitter.emitProject`. On nichobbs/cloud-agents (93 packages) that was most of
the ~20 s each linked entry took.

The probe is gone. The linked attempt is itself the check: it is compiled
with its diagnostics collected instead of printed
(`Emitter.emitProjectCollecting`), and `cmdTestManifest` decides what to
show. If the attempt builds, without leaving a call to the unresolved-call
stub, its collected diagnostics (warnings) are printed and its assembly runs.
Otherwise they are dropped, the entry is compiled with the library as before,
and a `note:` names the first error (`T0115: cannot resolve qualified
reference 'Fb.Lib.banner'`) or the unresolved call. The output therefore
shows only the build whose result is used; before, a codegen-time failure
such as a qualified read of a non-literal `pub val` (#6133) printed its
errors and then the fallback's result.

Collecting needed a diagnostics sink through the whole MSIL project compile,
not only the front end that `typeCheckProject` used:

- `Lyric.Pipeline.MiddleEndOptions.sink` (default: print) receives
  `pipeCheckAndMono`'s diagnostics, and `pipeWeave` and
  `specialiseWovenContracts` take one too.
- `Msil.Bridge.compileProjectToMsilWithRestoredAndVersionDiag` takes a
  `DiagSink`, passes it to `projectFrontEnd`, the middle end, the weaver and
  `abortOnCodegenDiagnosticsMsilInFiles`.
- `Lyric.Emitter.emitProjectCollecting(req, located)` compiles a dotnet
  project with a collecting sink; a codegen panic is collected too
  (`msilBridgePanicDiagnosticQuiet`) instead of printed.

`cmdTestManifest` builds every request of a run (the library build, the
linked attempt and the compile with the library) through one
`testBuildRequest` over a `TestBuildSettings` made once per run. A comment
records that the shared library build is made at most once per run and never
reused across runs.

`enum_case_collision_self_test.l` gains a below-the-CLI case for the restored
enum fixes of #8663: two restored packages declaring a case `Error` at
different ordinals, the one registered first not imported, and the app's bare
`Error` used as a call argument, in a restored record's field, in a match on
that field and in a comparison.

On nichobbs/cloud-agents, four entries run with `--suite` took 11, 9 and 10
seconds each after the first, against about 20 s each before; the first
includes the one library build (97 s for both).

Verified by `scripts/ci/test-runner-project-mode-e2e.sh` (which now also fails
if a run that passes prints an `error[` line), the enum self-test, and
`lyric test` in lyric-forms/derive, lyric-health, lyric-testing,
lyric-session and examples/ui-customers.
