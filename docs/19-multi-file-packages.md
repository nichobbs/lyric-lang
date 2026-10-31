# 19 — Multi-File Packages

**Status:** Shipped. Approved 2026-05-05 (PR #122 review).
**Implementation:** `Lyric.PackageMerge.assemblePackageFiles` (#8234, docs/70
§4.1 phase 2a); §3 and §4 describe the shipped compiler, which differs from
the original F#-era plan.
**Decision-log entry:** D180 (`docs/decisions/D180-package-merge-from-parses.md`).
**Superseded in part:** D267 (docs/70 §4.1) makes imports per file. Phase 2a (D300) has replaced the text merge with separately parsed files (§4) and given each file its own import scope (§4 step 2): a name a file sees only through a sibling's import is the error `T0219`. `B0012` stays until the passes that read aliases from the union of the files' imports read each file's own (#8690).

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
  in a package of one file too (a single file built on its own, with no
  manifest entry naming it, is named by its own declaration). A file with items, file-level
  annotations or imports but no `package` declaration is `P0020`. A file
  holding only comments contributes nothing.
- Parses on its own. Its parse diagnostics are reported against its own
  path and position, and stop the build.
- May declare its own imports independently of its siblings.
- Contributes its top-level declarations (types, funcs, consts, etc.)
  to the package's symbol table.
- May carry file-level annotations, which are the package's (§4 step 4a).

Subdirectories continue to be sub-packages: a subdirectory that is
another `[project.packages]` / `[project.tests]` entry's path is that
entry's package, and the parent entry's directory leaves it out (as it
leaves out a file another entry lists). A subdirectory that is no entry
of its own holds more files of the parent package, which declare the
parent's package (`B0013` otherwise); a build never assembles another
entry's files into a package.

## 3. Finding a package's files

A project build takes a package's files from its `[project.packages]`
entry (`Lyric.Discovery.projectEntryFiles`, shared by `lyric build`,
`lyric test` and `lyric prove`): a directory (every `.l` file under it,
sorted, except under another entry's path), one file, or an explicit
list. The stdlib and compiler per-package builds group their
trees' files by the package each file declares. No build looks a package
up by file name, so the single-file versus directory layout conflict the
original plan reserved `B0010` for cannot arise, and `B0010` is not
raised.

## 4. Assembling the files

`Lyric.PackageMerge.assemblePackageFiles` (`lyric-compiler/lyric/package_merge.l`)
builds one package from its files' parses; every backend's project front end
calls it through `Lyric.Pipeline.pipeParsePackageTo` (docs/70 §4.1, phase 2a):

1. **Parse** every file on its own, as file `i` of the package: every
   position of file `i` carries `Position.fileId = i` and the file's own
   line and column, and its offsets start at the file's offset base
   (`Lyric.Parser.fileOffsetBases`: file 0 at 0, each later file one past
   the normalised end of the file before it), so no two positions of the
   package share an offset. A file's parse diagnostics stop the build. Each
   file must declare the package (§2, `B0013`).
2. **Imports are per file.** Each file keeps its own imports
   (`FileHeader.imports`), and the type checker builds one import scope
   per file: the names a file may use bare or qualified are what its own
   imports make visible (language reference §9.2), its aliases and renames
   rewrite its own items only (`Lyric.AliasRewriter.rewriteFileReporting`),
   and its renames and selective imports are checked against its own
   imports (`T0148`, `T0210`). An item is checked in the scope of the file
   it is written in (`Position.fileId`); a synthesised item with no source
   position is checked against the union. A name a file can use only
   through a sibling file's import is `T0219 — 'X' is not imported by this
   file; only `import P` in <file> makes it visible, and a file's imports
   are its own: add `import P` to this file`, once per name and file.
   Later passes still read the union of the files' imports and the backends
   resolve bare names across the package, so a bare name that two files
   import from different packages is `T0123`, an alias that two files bind to
   different packages (`import Std.Core as A` in one, `import Std.Math as
   A` in another) is `B0012 — import alias A names Std.Math here but
   Std.Core at <file>:<line>`, reported against the later file, and a
   rename that collides with a name another file's import brings in is
   `T0148`, all until #8690. The same alias for the same package in two files
   is one import. The package also carries the union
   of the files' imports (`SourceFile.imports`, an import written in
   several files kept once), for synthesised items and the stages that
   need the package's dependencies. Phase 2a step 4 (#8676) introduced the
   rule as the warning `W0032` so the compiler, stdlib, ecosystem and users
   could add the missing imports first (docs/70 §12.2); D300 made it the
   error.
3. **File-level annotations** are package-wide: the package carries the
   union of its files' file-level annotations, an annotation written in
   several files kept once, and a file that writes none takes the
   package's. Two files that declare different verification levels
   (`@runtime_checked` / `@proof_required` / `@axiom`), or the same
   annotation with different arguments, raise `B0014`; `@pure` in one
   file against `@io` in another raises `Y0009` (the language
   reference's §9.4 rule).
4. **Unit-mode annotations** change how the whole package is parsed or
   compiled, so every file carries each of them or none does (`B0014`):
   `@contract_source` (block braces), the wrapping-arithmetic marker,
   `@test_module` and `@bench_module`.
5. **File-level `@cfg`** is per file: a file whose `@cfg` is false for
   the build's features and target (`target = "X"` is decided against
   the target being built) contributes no declaration or import. Its
   other file-level annotations still count, since they describe the
   package. A malformed or undeclared feature in it is `F0012` /
   `F0013`, as for an item's `@cfg`.
6. **Items**: each file's parsed items, in file order. The package keeps
   each file's own header (`SourceFile.files`: its path, module docs,
   annotations, `package` declaration, imports and offset base), so a
   comment in a header is never an item, and a `/* ... */` whose
   delimiters share lines with annotations still hides what it holds.
7. **Type-check + codegen**: identical to the single-file path. A name
   declared in two files is the type checker's duplicate-declaration
   error `T0001`, reported against the later file; the assembly raises no
   separate `B0011`.

Every diagnostic, in every phase, names the file it is in: its position's
`fileId` indexes the package's file paths
(`Lyric.DiagnosticUtil.diagFormatInFiles`), and it is printed as
`<path>: <severity>[<code>] <line>:<col>: <message>` with that file's own
line, or under the package's name when the file's path is unknown. The
JVM `LineNumberTable`, the weaver's `<package>:<line>` call sites and the
native backend's messages carry each file's own lines too.

A package of one file is its own parse (file 0, offset base 0). When a
manifest entry names it, it is still held to that name (`B0013`). Every
build path assembles its packages this way: `lyric build` and `lyric test`
on every target (`Lyric.Emitter.emitProject`, `emitNativeProject`; a
dependency compiled from source is assembled with its own features and the
weaver reads its templates from it), `lyric prove` on a project, and the
per-package builds of the stdlib and of the compiler itself
(`--internal-perpackage-build`, the compiler bundle). `lyric test
--doctests` on a single file compiles the file and its doctests as one test
module (`Lyric.TestSynth.withDoctests`: the doctests' imports join the
file's `package` line, their tests follow its last line, so no line of the
file moves); under a manifest a file's doctest module is one more file of
its package and carries the file's own imports.

## 5. Doc-comment merging

The module-level doc comments (`//!`) of every file in the package are
joined, in the package's file order, into the package's module doc
(`SourceFile.moduleDoc`), so a package of several files has the module doc a
package of one file has; each keeps its own file and line. `lyric doc`
documents each file on its own and is unchanged. A file turned off by its
file-level `@cfg` contributes no docs (as it contributes no items or
imports). A package of one file keeps its own docs as written (#8246).

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
- A file-private declaration tier (docs/70 Q-TIR-004). Imports are per
  file (§4 step 2), but every declaration of the package is visible in
  all of its files.

## 9. Diagnostic codes

| Code | Meaning | Status |
|---|---|---|
| `B0010` | package matches both single-file and multi-file layout | Not raised: no build finds a package by file name (§3). Raised by the removed F# emitter (D-progress-095) |
| `B0011` | duplicate declaration across files in same package | Not raised: the type checker's `T0001` reports it against the later file (§4 step 7). Raised by the removed F# emitter (D-progress-095) |
| `B0012` | conflicting import alias across files in same package | Shipped (#8234, D180); retired when the passes that read the union's aliases read each file's own (#8690) |
| `B0013` | a file of the package declares another package | Shipped (#8234, D180) |
| `B0014` | files of the package disagree on a file-level annotation | Shipped (#8234, D180) |

`B-` prefix introduced for "build / project-layout" diagnostics — same
prefix space `docs/20-project-as-dll.md` uses for project-level errors.

### B0012 collapse rule

Same alias targeting the same package across two files is silently
deduped (it's a redundant declaration, not a conflict).  Different
targets is the conflict that fires.
