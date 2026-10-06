# 19 — Multi-File Packages

**Status:** Drafted. Approved 2026-05-05 (PR #122 review).
**Implementation:** Phase 5 §M5.1 stage 2 (this branch follow-up).
**Decision-log entry:** to follow on landing.

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

- Declares the same `package <Head>.<…>` at the top. A file that names
  another package is `B0013`; a file with items and no `package`
  declaration is `P0020`, as a single-file build reports it. A file
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

## 3. Resolver changes

The current built-in-head resolver in `Emitter.fs:locateBuiltinFile`
returns a single `string option`. It becomes
`locateBuiltinFiles : … -> string list` returning every file that
matches the package's snake-case basename.

```fsharp
let private locateBuiltinFiles
        (startDir: string)
        (segments: string list) : string list =
    // … existing root-walking + env-var override …
    // For each candidate root, return:
    //   1. <root>/<basename>.l                (single-file form)
    //   2. <root>/<basename>/*.l              (multi-file form)
    //   3. <root>/_kernel/<basename>.l        (audited extern boundary)
    //   4. <root>/_kernel/<basename>/*.l      (kernel multi-file)
```

If a package has *both* `lexer.l` AND a `lexer/` subdirectory, the
emitter raises a build error: `B0010 — package <X>.<Y> matches both a
single-file and multi-file layout; use one`. Single-file form remains
the default; multi-file is a directory-shaped opt-in.

## 4. Compilation pipeline changes

`Emitter.fs:emitAssembly` is rewritten from `SourceFile -> EmitResult`
to `SourceFile list -> EmitResult`. The pipeline becomes:

1. **Lex + parse** every file. Each parse produces a `SourceFile`.
2. **Merge declarations**: walk every parsed file's top-level decls
   into a single `SourceFile.Declarations` list (preserving file +
   span info on each decl).
3. **Conflict diagnostics** before type-checking: if two decls share
   a name + arity (functions) or bare name (records/unions/etc.) in
   the same package, emit `B0011 — duplicate declaration '<name>' in
   package <X>.<Y>; first defined in <file>, also in <file>`. This is
   a hard error; the dupe is dropped from the merged item list so
   downstream type-checking sees a clean symbol table.
4. **Imports**: union each file's imports, deduping identical imports.
   Conflicting aliases (`import Std.Core as A` in one file, `import
   Std.Math as A` in another) raise `B0012 — conflicting import alias
   '<A>' in package <X>.<Y>: maps to <X> in <file> but to <Y> in
   <file>`. Same alias for the same target across files dedupes
   silently.
4a. **File-level annotations** are package-wide: the merged package
   carries the union of its files' file-level annotations, an annotation
   written in several files kept once, and a file that writes none takes
   the package's. Two files that declare different verification levels
   (`@runtime_checked` / `@proof_required` / `@axiom`), or the same
   annotation with different arguments, raise `B0014`; `@pure` in one
   file against `@io` in another raises `Y0009` (the language
   reference's §9.4 rule). A file-level `@cfg` is per file instead: a
   file whose `@cfg` is false for the build's features contributes no
   declaration or import (its other file-level annotations still count,
   since they describe the package), and a malformed or undeclared
   feature in it is `F0012` / `F0013`, as for an item's `@cfg`.
5. **Type-check + codegen**: identical to the single-file path
   (records / unions / funcs / etc. all live in the merged symbol
   table; codegen emits one CLR type per Lyric record / union, one
   method per func, one resource per package).

### 4.1 Implementation (#8234)

`Lyric.PackageMerge` (`lyric-compiler/lyric/package_merge.l`) builds the
merged unit from each file's parse, never from its text alone: the merged
unit is the files' united file-level annotations, one `package` line, the
files' united imports, then each file's text after its header. Each
file's header tokens (module docs, annotations, `package`, imports) are
removed by their parse spans, and comments in the header are kept as
comments, so a `/* ... */` whose delimiters share lines with annotations
still hides what it holds. A line that held only header tokens (and
white space or a line comment) is dropped; every other line keeps its
place, and the merge records, for every merged line, the file and line
it came from, which diagnostics report instead of the merged unit's own
numbering. A package of one file is
compiled as written. Every multi-file build path uses it: `lyric build`
and `lyric test` on every target (`Lyric.Emitter.emitProject`,
`emitNativeProject`), the dependency packages a build weaves aspect
templates from, and the per-package builds of the stdlib and of the
compiler itself (`--internal-perpackage-build`, the compiler bundle).
`lyric prove` proves one file at a time and reads its siblings' type
names from their own parses, so it needs no merged unit.

The merge itself does not raise `B0011` / `B0012`: a declaration repeated
across files is the type checker's `T0001` over the merged unit, reported
against the later file's own path and line.

## 5. Doc-comment merging

Module-level doc comments (`//!`) from every file in the package are
concatenated in deterministic file-name order with a blank line
between, joined into the package's contract-metadata `ModuleDoc`
field. `lyric doc` already reads that field; no further change.

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
| `B0010` | package matches both single-file and multi-file layout | Shipped (D-progress-094 follow-up) |
| `B0011` | duplicate declaration across files in same package | Shipped (D-progress-094 follow-up) |
| `B0012` | conflicting import alias across files in same package | Shipped (D-progress-094 follow-up) |
| `B0013` | a file of the package declares another package | Shipped (#8234) |
| `B0014` | files of the package disagree on a file-level annotation | Shipped (#8234) |

`B-` prefix introduced for "build / project-layout" diagnostics — same
prefix space `docs/20-project-as-dll.md` uses for project-level errors.

### B0011 key shape

The duplicate-declaration check keys on `kind:name` plus arity for
functions:

* `func add/2` and `func add/3` are legitimate overloads-by-arity and
  do NOT trigger B0011.
* `func add/2` declared in two files is a conflict.
* Records, unions, enums, opaque types, etc. key on bare name — there
  is no overloading on these shapes.
* Anonymous declarations (`impl …`, `test "…"`, `fixture …`) are not
  flagged because they have no global identifier.

### B0012 collapse rule

Same alias targeting the same package across two files is silently
deduped (it's a redundant declaration, not a conflict).  Different
targets is the conflict that fires.
