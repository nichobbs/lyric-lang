# Constructor and function names resolved by package scope on dotnet and the JVM, `lyric-testing` on the JVM (#9130, #9135)

Decision: D609.

The native backend fixed cross-package name collisions in #9129 (D606, D607
progress note); the same two-package programs failed on dotnet
(`InvalidProgramException`) and on the JVM (`VerifyError`, `ClassCastException`).

## Root cause

Both managed backends tried a call as a construction first and looked the
constructor up by its bare name in a bundle-wide table:

- MSIL (`Msil.Codegen.lowerBuiltinOrStaticCallMsil`): `unionCaseCtorByName[name]`
  with a single candidate was taken whatever package declared it
  (`pickCaseFqnByQualifier`/`pickCaseFqnByScope` return a lone candidate unseen), so a call of
  the function `Token(10)` was built as the unrelated package's case `Token`, and the
  function `Marker(2)` as another package's case `Marker` (a wrong value, not even a crash).
  A case of a package out of scope also beat a record of an imported package.
- JVM (`lowerGeneralStaticCall`): `ctorClassForExpecting` ended in the bundle-wide first-wins bare
  entry (`bundleCtorFallback`) before any function lookup, with the same results.

The type checker had already resolved every one of these calls: it records the function a
call resolved to (`calleeSites`, D336) and both bridges carry it.

## Fix

- MSIL: a call the checker resolved to a function is never a construction
  (`callResolvedToFunctionMsil`). A bare constructor name takes the nearest scope that declares
  a case (`caseCandidatesLevelMsil`, `scopedCaseCandidatesMsil`: own package, imports, else all), and a
  record of a nearer scope beats a case of a farther one.
- JVM: the same site test; the bundle-wide constructor entry is consulted only when no function
  is in scope (`ctorClassForExpectingScoped`, `bundleCtorFallback` after the function lookup). A bare
  call with no checker site now resolves through the file's imports (`importedFuncSigJvm`), which
  `lyric-testing` needs (below).
- Not done: lowering from the checker's resolved symbol for constructors (docs/70 phase 4). The checker
  records no per-call symbol for constructor calls yet, so this is scope-by-scope resolution, as on
  native; the last tier (nothing in scope) still takes the bundle-wide name, as native does.

## `lyric-testing` on the JVM (#9135)

`MockMessageQueue implements Mq.MessageQueue`, whose `publishBatch` has `requires: allHaveIds(messages)`.
The elaborator copies that clause into the implementing package, where the checker has no call
site for it (the span belongs to `lyric-mq`'s file). MSIL finds `allHaveIds` through the imports of the package; the
JVM resolved a bare name only through a site or the package's own scoped key, so JVM codegen failed with
`J002`. The import-scope lookup above resolves it, and `lyric-testing` declares `"jvm"` again.
Known gap: such a clause is resolved in the implementer's scope, not the interface's declaring package's
(the elaborator does not know the declaring package of an imported interface).

## Tests

`msil_project_bridge_self_test.l` and `jvm_cross_package_collision_self_test.l` gain three tests each:
the reported shape, and `Col.A`/`Col.Z` (case/record, case/function, record/record, case/case, generic
case/record, generic record/case, function/case, enum cases, distinct type/case) built in every package
order, called qualified and bare.

`lyric-testing`'s README, manifest comment, CLAUDE.md line, the book's matrix row and
`scripts/ci/testing-tests.sh` (now also `lyric test --target jvm` for `lyric-conformance` and
`lyric-testing`, behind a Java setup step that `ci.yml` moved ahead of it) say it builds for the
JVM. D604's note that `lyric-testing` is dotnet-only is superseded by D609; the census script
builds a manifest for the targets it declares, so it now builds this one for the JVM.
