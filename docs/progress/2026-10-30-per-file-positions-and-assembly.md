# Per-file positions and package assembly, docs/70 phase 2a steps 1-2 (#8612)

The first slice of docs/70 phase 2a, the move from text-merged multi-file
packages to separately parsed files with per-file imports:

- `Lyric.Lexer.Position` names its file (`fileId`). `lexFile` and
  `Lyric.Parser.parseFile(source, fileId, offsetBase)` lex a file of a package
  with its own lines and columns, at an offset base past the files before it,
  so offsets stay unique across the package and the offset-keyed side tables
  the checker hands to later passes keep their meaning (docs/70 §4.1).
- `spanKey`, `sameSpan` and `spanWithin` are the shared span helpers; the
  checker, pipeline, contract elaborator and verifier no longer carry their
  own offset-only copies.
- `SourceFile.files` keeps every file's own header (`FileHeader`: path,
  imports, file-level annotations, module doc, offset base); `imports` stays
  the union.
- `Lyric.PackageMerge.assemblePackageFiles` joins a package's separately
  parsed files into one `SourceFile` under the merge's header rules (B0012,
  B0013, B0014, P0020, F0012/F0013, unit modes). `package_merge_self_test`
  checks it against `mergePackageFiles` for the same files.

No build uses the assembly yet: moving the MSIL, JVM and native paths onto it,
then per-file import scopes, are the next steps of #8612. Nothing that a
program can observe changes.
