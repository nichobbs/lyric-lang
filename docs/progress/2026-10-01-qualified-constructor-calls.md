# Qualified constructor calls (D159)

The first half of #7564 (renaming a selectively imported name): every
kind of item now has a qualified form that the rename can lower to.

- **Language.** docs/01 §2 used to say a constructor call must use an
  unqualified type name. It now allows a record constructor qualified by
  its package's path or alias (`Geo.Point(...)`, `G.Point(...)`), and a
  union case qualified by its union, itself bare or qualified
  (`G.Shape.Circle(...)`, `G.Shape.Empty`). The written qualifier decides,
  so a qualified call builds the qualifier's type even when the current
  package declares the same simple name.
- **MSIL fix.** MSIL looked up the current package's `<pkg>.<name>` key
  before the written qualifier. `G.Point(...)` in a package with its own
  `Point` therefore built the local record, which failed at run time with
  `InvalidProgramException`.
  - Every site that maps a call or a value to a constructor now resolves a
    qualified path first (`qualifiedRecordCtorKeyMsil`,
    `qualifiedCaseCtorKeyMsil`).
  - A nullary case behind a package-qualified union (`Pkg.Shape.Empty`)
    resolves too; it was T0121.
- **Other targets.** The type checker, JVM and native already resolved by
  the qualifier.
- **Tests.** `qualified_ctor_self_test.l`, in CI on dotnet and the JVM: a
  package-qualified and an alias-qualified record constructor, and
  union-qualified cases. Each test runs next to local declarations that
  share `Std.JsonValue`'s names.
