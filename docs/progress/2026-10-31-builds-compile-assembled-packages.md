# Builds compile assembled packages; the text merge is deleted, docs/70 phase 2a step 3 (#8612)

Every build path now hands a backend a package as its files (sources and
paths) and the backend's front end parses each file on its own and assembles
the package from the parses (`Lyric.Pipeline.pipeParsePackageTo` over
`Lyric.PackageMerge.assemblePackageFiles`, docs/19 §4):

- The MSIL, JVM and native project front ends parse every package this way
  (`Msil.Bridge.ProjectPackagePayload.sources/paths`,
  `Lyric.LlvmBridge.NativeSourcePackage.sources/paths`, `Lyric.Pipeline.PackageFiles`
  for the JVM bridge), as do the dependency-template reads
  (`pipeParseDependencyPackage`, with the dependency's own features).
  `Lyric.Emitter.emitProject`, `emitNativeProject`, `typeCheckProject` (`lyric
  prove`), the per-package stdlib and compiler builds and the compiler bundle
  no longer merge anything first.
- Diagnostics name their file through the package's file-path table indexed
  by `Position.fileId` (`Lyric.DiagnosticUtil.diagFilePath`,
  `diagFormatInFiles`, `diagReportAndAbortInFiles`;
  `MiddleEndOptions.filePaths`), printed as `path: severity[code] line:col:
  message` with the file's own line, or under the package's name when the
  path is unknown. `diagLocate`/`diagLocateAll` keep serving `lyric prove`.
- Deleted: the merge's text assembly (`mergePackageFiles`,
  `mergeDiscoveredPackage`, the header-blanking and line-origin code),
  `MergedLineOrigin`, `PackageLineOrigins`, `diagFormatWithOrigin`,
  `diagReportAndAbortInPkgWithOrigins`, and every `origins`/`originsByPkg`
  parameter of the bridges and the pipeline.
- `Lyric.Parser.fileOffsetBases` is the one place a package's offset bases
  are computed; `parseFile` documents that its `source` (and so its CST)
  indexes the file's own text at `offset - offsetBase`.
- `lyric test --doctests` on a single file compiles the file and its
  doctests as one test module (`Lyric.TestSynth.withDoctests`): the doctests'
  imports join the file's `package` line and their tests follow its last
  line, so no line of the file moves. A doctest module (`buildDoctestModule`)
  now carries the documented file's own imports, ready for per-file import
  scopes.

Behaviour visible in output:

- A package's merge diagnostics (B0012-B0014, P0020, F0012/F0013 on file-level
  `@cfg`) are reported when the backend parses that package, with the
  package's other parse diagnostics, instead of in a pass over every package
  before the build; a build stops at the first package with an error, as it
  already did for parse errors. The "a package's files do not merge into one
  package" summary line is gone.
- Parse warnings of a multi-file package come from each file's own parse,
  at that file's position; before, they came from a reparse of the merged
  text, translated back through its line table.
- A package of one file whose file-level `@cfg` turns it off no longer keeps
  its imports (it already lost its items), as a gated-off file of a
  multi-file package did.
- On dotnet, a package compiled from a dependency's source is erased with
  the dependency's own features (`ProjectPackagePayload.features`), as on the
  JVM and native targets.
- A diagnostic in a multi-file package is never at a merged-text line, so
  the weaver's `<package>:<line>` call sites, the JVM `LineNumberTable` and
  native messages carry each file's own lines.
- Two identical file-level annotations or imports in one file are kept as
  written, as for a package of one file; only a repeat across files is
  dropped.

`package_merge_self_test` asserts the assembled `SourceFile` (items with their
file and line, imports, annotations, module docs, file headers, offset bases)
for every case it once checked against merged text, and
`source_path_diagnostics_self_test` adds multi-file type-error cases for the
JVM and native targets and a B0013 case against the second file's own line.
Per-file import scopes, which retire `B0012`, are the next step of #8612.
