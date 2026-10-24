# D230 — A `@test_module` that declares a project package is merged into it; `--doctests`

**Status:** accepted, implemented (#678)

Resolves the "cross-package non-`pub` access" and "doctests" items of the test
runner v2 (docs/24 §4, §5 Stage 3, Q-test-4).  `--manifest` discovery and
`--update-snapshots`, the other two items of #678, were already shipped
(D-progress-297, #6906).

## Context

`docs/01` §3.2 has always said a `@test_module` may reach the non-`pub`
declarations of the package it tests, but no mechanism implemented it: the
runner compiled the test module as a package of its own, so a `package
Account` test next to a `package Account` source was two packages of one
name.  The reference gave no rule for how a test module names its target.

## Decision

1. **The test module is merged into the package.**  A `@test_module` whose
   `package` is the name of a `[project.packages]` entry is compiled as one
   more file of that package (after the entry's own files).  It sees what the
   package's files see because it is one of them.  This is the same merge
   `Lyric.PackageMerge` does for every multi-file package (docs/19, D180), so
   no new visibility rule exists in the checker, and every backend gets it
   for free.
2. **The name decides, nothing else.**  A test module of another package
   (`package Account.Tests`) stays a separate package and sees `pub` items
   only; that is how a black-box test is written.  There is no annotation
   argument naming a target, because the package line already is that name.
3. **`@test_module` is dropped from the merged file.**  The files of a package
   must agree on `@test_module` (B0014), and the package under test is not a
   test module.  The rewrite `Lyric.TestSynth` produced has no `test` item
   left in it by then (they are functions and a `main`), so nothing downstream
   reads the annotation.  The annotation is blanked with spaces, so no line
   or column moves.  A file of the package that is the test file itself (a test
   kept in the package's directory) is not added twice.
4. **Single-file mode follows the manifest.**  `lyric test tests/x.l` merges
   when the nearest `lyric.toml` lists the package; the dependencies the
   package's other files import are resolved like any project package's.  The
   merge is requested by `lyric test` only: `lyric build`/`run`/`check` of a
   file keep compiling just that file.
5. **The test package is the entry package.**  The synthesised `main` is in
   the merged package, which is also the JVM main class.
6. **Doctests are tests of the package they document.**  `--doctests` runs
   the runnable ` ```lyric ` blocks of doc comments.  `extractDoctests` reads
   them from the lexer's doc-comment tokens (so a comment on any item or
   member counts), and `buildDoctestModule` turns a file's blocks into a
   `@test_module` of the file's own package, one `test` per block, titled
   `doctest <path>:<line>`.  That module then follows rule 1, so a doctest
   sees the package's private items too.  Imports at the head of a block are
   hoisted to the module.  A block is a statement list.  Opt-out is the fence
   attribute `no_test`/`ignore` or a first line `// no_test`.

## Alternatives considered

* A visibility exception in the type checker for packages marked test modules
  (rejected: a second visibility rule for every backend and for contract
  metadata, when the merge needs none).
* An annotation `@test_module(for = "Account")` (rejected: a second spelling of
  the package name, which could disagree with it).
* Extracting doctests from the AST's `docComments` (rejected: member-level
  docs are not all attached to items, and the lexer's tokens carry the line
  of every comment line, which is what the test title needs).
