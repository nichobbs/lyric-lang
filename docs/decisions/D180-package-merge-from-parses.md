# D180 - A multi-file package is the union of its files' parses

**Status:** accepted

Settles #8234. Codifies docs/19 §2-§4 and docs/01 §9.1.

## Context

A package of several files is compiled as one unit. The merge used to build that unit by deleting header lines from each file's text (`@`, `//!`, `import `, `package ` at a line start) and concatenating the rest. It had no lexical context: a block comment whose delimiters shared lines with annotations lost them and its contents went live, a file with a broken header or another package's name was compiled in, and only the first file's file-level annotations reached the package. File-level `@cfg(target = ...)` was never decided, so a file for another target stayed in.

## Decision

1. **Each file stands alone.** Every file of a package parses on its own; its parse diagnostics name its own path and position and stop the build. The merged unit is the files' parsed headers combined (below), then each file's text after its header with the header tokens removed by their parse spans. Comments in a header stay comments.
2. **Every file declares its package** (B0013). A file whose `package` declaration names another package than its manifest entry is B0013, in a package of one file as well. A file with items, file-level annotations or imports but no `package` declaration is P0020. A file of comments only contributes nothing.
3. **Imports are shared.** The package's imports are the union of its files' imports, a repeated import kept once. Because the files share one scope, an alias two files bind to different packages is B0012.
4. **File-level annotations are package-wide.** The package carries the union of its files' file-level annotations, a repeated one once; a file that writes none takes the package's. Files that declare different verification levels, or the same annotation with different arguments, are B0014; `@pure` in one file against `@io` in another is Y0009 (§9.4's existing rule).
5. **Unit-mode annotations agree.** `@contract_source`, the wrapping-arithmetic marker, `@test_module` and `@bench_module` change how the whole unit is parsed or compiled, so a union would impose one file's mode on the others. Every file carries each of them or none does (B0014).
6. **`@cfg` is per file, and the target decides it.** A file whose file-level `@cfg` is false for the build's features and target (`target = "X"` decided against the target being built) contributes no item and no import. Its other file-level annotations still describe the package. A malformed or undeclared feature in a file-level `@cfg` is F0012 / F0013.
7. **Duplicates are the checker's.** A name declared in two files is T0001 from the type checker over the merged unit, against the later file. The merge raises no B0011, and B0010 (a package found both as a file and as a directory) cannot arise, since no build finds a package by file name.

## Consequences

- The merged text of a well-formed package is what the old merge produced, so the stdlib and compiler per-package builds are byte-identical. A package whose first file lacked an annotation another file has now carries it (`lyric-search`'s `Search` gains `@runtime_checked` on the JVM).
- The merge records the origin of every merged line, including the merged header's annotation and import lines, so later diagnostics name the right file.
- Module docs (`//!`) of a multi-file package are still dropped (docs/19 §5, #8246).

## Tests

`package_merge_self_test.l`; `scripts/ci/multi-file-package-merge-e2e.sh` on dotnet, the JVM and native.
