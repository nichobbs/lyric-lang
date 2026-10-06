# Multi-file packages merge from their files' parses (#8234)

A package of several files used to be merged by editing its files' text line
by line (`Lyric.Emitter.mergePackageSources`): every header line starting
`@`, `//!`, `import ` or `package ` was deleted, with no lexical context. A
`@runtime_checked /*` ... `@runtime_checked */` pair before `package` lost
both comment delimiters, so the declarations between them became live code;
a file with a broken header, or one declaring another package, was compiled
into the package anyway; and only the first file's file-level annotations
reached the package (a `@proof_required` on any other file was dropped).

The merge now lives in `Lyric.PackageMerge`
(`lyric-compiler/lyric/package_merge.l`) and works from each file's parse:

- Every file must parse on its own; its parse diagnostics are reported
  against its own path and position and stop the build.
- Every file must declare the package its manifest entry names: another
  package is the new `B0013`, in a package of one file too when a manifest
  entry names it (also for a file whose header does not parse, from the
  first `package` declaration among its tokens). A single file built on its
  own is named by its own declaration, read with comments skipped; the
  line scans that named it (`Release.packageNameOf`, the test runner's,
  `importedPackageNames`, the layers header read) all read the header that
  way now.
- A directory entry leaves out a subdirectory that is another entry's path
  (a sub-package) and a file another entry lists, in `lyric build`,
  `lyric test` and `lyric prove` alike (`Lyric.Discovery.projectEntryFiles`);
  a plain subdirectory still holds more files of the entry. A file with items, file-level annotations or imports and no
  `package` declaration is `P0020`; a file of comments only contributes
  nothing.
- The merged unit is the files' united file-level annotations, one
  `package` line, the files' united imports (identical imports kept once,
  as before), then each file's text after its header. Header tokens are
  removed by their parse spans; comments in a header stay comments, and a
  line that held a header token next to a piece of a block comment is kept
  with the token blanked. Lines that held only header tokens are dropped,
  so a well-formed package merges to exactly the text it did before.
- An import alias that two files bind to different packages is `B0012`:
  the files share one scope. (A renamed selective import bound two ways is
  the checker's `T0148`.)
- File-level annotations are package-wide: an annotation written in several
  files counts once, and a file that writes none takes the package's. Files
  that declare different verification levels, or one annotation with
  different arguments, are the new `B0014`; `@pure` against `@io` across
  files is `Y0009`. `@contract_source`, the wrapping-arithmetic marker,
  `@test_module` and `@bench_module` change how the whole unit is parsed or
  compiled, so every file carries each of them or none does (`B0014`).
- A file-level `@cfg` stays per file and is now decided against the build's
  target too: `@cfg(target = "jvm")` keeps a file out of a dotnet or native
  build, which the old merge never did. A file it turns off contributes no
  item or import, while its other file-level annotations still describe the
  package. A malformed or undeclared feature in it is now reported
  (`F0012` / `F0013`).
- A name declared in two files stays the type checker's `T0001`, against the
  later file; `B0010` / `B0011` are not raised by the self-hosted compiler
  (docs/19 §3, §9).
- Each merged line still maps to its file and line, now including the
  annotation and import lines of the merged header.

Every merge site uses it: `emitProject` (dotnet and JVM; a dependency the
JVM or native build compiles from source is merged once, with its own
features, and the weaver reads that unit), `emitNativeProject`, and the
stdlib and compiler per-package builds (`loadStdlibPayloads` /
`loadCompilerPayloads`, behind `--internal-perpackage-build` and the
compiler bundle). Those discover a tree's packages from a lexically-aware
header scan (`PackageMerge.scanHeader`, which skips comments and annotation
strings) instead of the line splitter. `lyric test --manifest` now hands
every file of a library package to the build, and decides a one-file
package's `@cfg` on its parse with the target; the text-based `Lyric.CfgGate`
package and its tests are removed. `lyric prove` proves one file at a time
and needs no merged unit. Module docs of a multi-file package are still
dropped (docs/19 §5, #8246). Decision: D180.

Verified: `package_merge_self_test.l` (24 cases) and
`scripts/ci/multi-file-package-merge-e2e.sh` on dotnet, JVM and native
(both #8234 repros rejected, a header block comment stays a comment,
target-gated files, a nested sub-package, single files beside a manifest, B0012 / B0013 / B0014 / P0020 against the right file
and line); the whole compiler and stdlib
closure emitted through `--internal-perpackage-build` is byte-identical to
main's over the same sources (130 DLLs), as are 13 ecosystem libraries'
project builds on dotnet and JVM, except `lyric-search` on the JVM: its
`Search` package now carries `search.l`'s `@runtime_checked`, which the old
merge dropped because the first file in the package (a backend file) has
no level of its own; the extra header line shifts the JVM line numbers.
Docs: docs/19, docs/01 §9.1, D180, book chapter 6 and appendix B.
