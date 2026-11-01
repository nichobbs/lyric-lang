# `pub use` re-exports, D141's transitive reach is W0033, docs/70 phase 2c step 1 (#8612)

D309.

- **`pub use P`** re-exports the whole package.
  - `ImportedPackage.reexports` is filled from the package's `pub use`
    lines by every bridge (MSIL, JVM, native, LSP) and from the contract
    metadata key `reexports` for restored dependencies.
  - The symbol table records each package's re-exports
    (`symTableRegisterPackageReexports`).
  - A selective import of a package also lists the names it re-exports
    (`reexportClosure` in `collectImportSets`).
- **W0033.**
  - `collectImportSets` marks the packages of a file's whole set that no
    direct import or chain of re-exports reaches (`transitiveOnly`, with
    the first non-re-export import on the chain).
  - The union and each file's `FileImportRule` carry them.
  - `symTableNoteBareUse`, `symTableNoteBareFuncUse` and
    `symTableNoteQualifiedUse` report a bare name or a qualified type path
    that relies on them.
  - `symTableNoteQualifiedReexport` reports a qualified call or function
    value through a package that imports, but does not re-export, the
    callee's package.
- **Migration.**
  - `Std.Collections` and `Std.Json` `pub use` their hosts.
  - `msil/codegen.l` qualifies its `Std.String` calls.
  - Other files add the imports they rely on: JVM codegen, CLI,
    `type_alias_resolve.l`, `Std.Http`, `Std.Plugin`, `lyric-forms`,
    `lyric-ui`, `lyric-docker`, `lyric-validation`, a fixture.
  - Census: 635 W0033 before, 1 after (#8709).
- **Doctests** keep a module's `pub use` as an import.

Tests: `typechecker_self_test` (W0033 and its exceptions, the two-hop
message, selective re-exports, cases), the updated #7799 and kernel/host
idiom cases.

Docs: language reference §9.2 and §9.3, docs/70 (phase 2c status, §14),
book chapter 6 and appendix B.
