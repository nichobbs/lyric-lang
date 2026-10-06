# 19 — Multi-File Packages

**Status:** Shipped. Approved 2026-05-05 (PR #122 review).
**Implementation:** `Lyric.PackageMerge` (#8234); §3 and §4 describe the
shipped compiler, which differs from the original F#-era plan.
**Decision-log entry:** D180 (`docs/decisions/D180-package-merge-from-parses.md`).

## 1. Motivation

Today every Lyric `.l` file declares one `package` and produces one
DLL. A multi-thousand-line package — like the self-hosted lexer
shipped in `lyric-compiler/lyric/lexer.l` — must be a single source
file. There is no way to split a package across files even when the
split would be obvious (token types in one file, the lex driver in
another, keyword tables in a third).

This document specifies the smallest change that lets one package span
multiple files without changing the language, the contract metadata
shape, or the DLL output. Project-as-DLL bundling and cross-package
optimisations are deferred to `docs/20-project-as-dll.md`.

## 2. Source layout

A package may now consist of any number of `.l` files in the same
directory. Each file:

- Declares the same `package <Head>.<…>` at the top: the package its
  manifest entry names. A file that names another package is `B0013`,
  in a package of one file too. A file with items, file-level
  annotations or imports but no `package` declaration is `P0020`. A file
  holding only comments contributes nothing.
- Parses on its own. Its parse diagnostics are reported against its own
  path and position, and stop the build.
- May declare its own imports independently of its siblings.
- Contributes its top-level declarations (types, funcs, consts, etc.)
  to the merged package symbol table.
- May carry file-level annotations, which are the package's (§4 step 4a).

Subdirectories continue to be sub-packages, as they are today.
`lyric-compiler/lyric/lexer/` would still be the package
`Lyric.Lexer`; the **files** inside it are merged.

## 3. Finding a package's files

A project build takes a package's files from its `[project.packages]`
entry: a directory (every `.l` file under it, sorted), one file, or an
explicit list. The stdlib and compiler per-package builds group their
trees' files by the package each file declares. No build looks a package
up by file name, so the single-file versus directory layout conflict the
original plan reserved `B0010` for cannot arise, and `B0010` is not
raised.

## 4. Merging the files

`Lyric.PackageMerge.mergePackageFiles` (`lyric-compiler/lyric/package_merge.l`)
builds one compilation unit per package from the files' parses:

1. **Parse** every file on its own. A file's parse diagnostics are
   reported against its own path and position and stop the build. Each
   file must declare the package (§2, `B0013`).
2. **Imports**: the union of the files' imports, an import written in
   several files kept once. An alias that two files bind to different
   packages (`import Std.Core as A` in one, `import Std.Math as A` in
   another) is `B0012 — import alias A names Std.Math here but Std.Core
   at <file>:<line>`, reported against the later file; the files share
   one scope, so an alias names one package. The same alias for the same
   package in two files is one import.
3. **File-level annotations** are package-wide: the merged package
   carries the union of its files' file-level annotations, an annotation
   written in several files kept once, and a file that writes none takes
   the package's. Two files that declare different verification levels
   (`@runtime_checked` / `@proof_required` / `@axiom`), or the same
   annotation with different arguments, raise `B0014`; `@pure` in one
   file against `@io` in another raises `Y0009` (the language
   reference's §9.4 rule).
4. **Unit-mode annotations** change how the whole unit is parsed or
   compiled, so every file carries each of them or none does (`B0014`):
   `@contract_source` (block braces), the wrapping-arithmetic marker,
   `@test_module` and `@bench_module`.
5. **File-level `@cfg`** is per file: a file whose `@cfg` is false for
   the build's features and target (`target = "X"` is decided against
   the target being built) contributes no declaration or import. Its
   other file-level annotations still count, since they describe the
   package. A malformed or undeclared feature in it is `F0012` /
   `F0013`, as for an item's `@cfg`.
6. **Items**: each file's text after its header, in file order. Each
   file's header tokens (module docs, annotations, `package`, imports)
   are removed by their parse spans, and comments in the header are kept
   as comments, so a `/* ... */` whose delimiters share lines with
   annotations still hides what it holds. A line that held only header
   tokens (and white space or a line comment) is dropped; every other
   line keeps its place. The merge records, for every merged line, the
   file and line it came from, which diagnostics report instead of the
   merged unit's own numbering.
7. **Type-check + codegen**: identical to the single-file path. A name
   declared in two files is the type checker's duplicate-declaration
   error `T0001`, reported against the later file's own path and line;
   the merge raises no separate `B0011`.

A package of one file is compiled as written (its header is still read
for `B0013`). Every build path uses the merge: `lyric build` and
`lyric test` on every target (`Lyric.Emitter.emitProject`,
`emitNativeProject`; a dependency compiled from source is merged once
and the weaver reads that unit), and the per-package builds of the stdlib
and of the compiler itself (`--internal-perpackage-build`, the compiler
bundle). `lyric prove` proves one file at a time and reads its siblings'
type names from their own parses, so it needs no merged unit.

## 5. Doc-comment merging

**Not implemented.** The plan: module-level doc comments (`//!`) from
every file in the package are concatenated in deterministic file-name
order with a blank line between, into the package's contract-metadata
`ModuleDoc` field. Today the merge drops every file's `//!` comments
from the merged unit (a `//!` is only valid before `package`), so a
package of several files has no module doc in its metadata; a package of
one file keeps its own. Tracked in #8246.

## 6. Format / lint

- `lyric fmt` operates per-file as today; canonical style is
  unchanged.
- `lyric lint` accumulates package-wide warnings (e.g. an `internal`
  symbol unused across files — once `internal` exists per
  `docs/20-project-as-dll.md` — surfaces against the file that
  declares it).

## 7. Migration path

Existing single-file packages continue to work. A package in the form
`pkg/foo.l` can be split by:

1. `mkdir pkg/foo && git mv pkg/foo.l pkg/foo/foo.l`.
2. Splitting `pkg/foo/foo.l` into multiple files.
3. No imports change; no consumers change.

The bootstrap stdlib + JVM package + self-hosted lexer all stay
single-file initially. The lexer is the most likely candidate for an
early split: token types into `tokens.l`, keyword table into
`keywords.l`, lex driver into `lexer.l`.

## 8. Out of scope

- Cross-package consolidation into one DLL. (See
  `docs/20-project-as-dll.md`.)
- Glob imports or wildcard `import pkg.*`. Ruled out by §1.4 of the
  language reference.
- Source-tree-relative import paths. Ruled out by the built-in-head /
  restored-package model.
- Per-file visibility scopes. There is no "file-private" tier; the
  merged symbol table makes file boundaries invisible at the package
  level.

## 9. Diagnostic codes

| Code | Meaning | Status |
|---|---|---|
| `B0010` | package matches both single-file and multi-file layout | Not raised: no build finds a package by file name (§3). Raised by the removed F# emitter (D-progress-095) |
| `B0011` | duplicate declaration across files in same package | Not raised: the type checker's `T0001` reports it against the later file (§4 step 7). Raised by the removed F# emitter (D-progress-095) |
| `B0012` | conflicting import alias across files in same package | Shipped (#8234, D180) |
| `B0013` | a file of the package declares another package | Shipped (#8234, D180) |
| `B0014` | files of the package disagree on a file-level annotation | Shipped (#8234, D180) |

`B-` prefix introduced for "build / project-layout" diagnostics — same
prefix space `docs/20-project-as-dll.md` uses for project-level errors.

### B0012 collapse rule

Same alias targeting the same package across two files is silently
deduped (it's a redundant declaration, not a conflict).  Different
targets is the conflict that fires.
