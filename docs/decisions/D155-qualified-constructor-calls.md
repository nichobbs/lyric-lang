# D155 — Qualified constructor calls; the written qualifier decides

**Status:** accepted, implemented

Prerequisite for #7564 (`import P.{f as g}`), which lowers a renamed
name to its qualified form.

## Context

docs/01 §2 said a constructor call must use an unqualified type name, and
that `Pkg.Point(...)` is not a constructor call. The implementation had
moved past that:
- the type checker accepted `Pkg.Point(...)`, `Alias.Point(...)` and
  `Pkg.Shape.Circle(...)`;
- the JVM and native backends built the qualifier's type;
- the MSIL backend looked up the current package's key
  (`<pkg>.<name>`) before the written qualifier.

So on MSIL, `G.Point(x = 3, y = 4)` in a package that declares its own
`Point` built the local record. That compiled to invalid IL
(`InvalidProgramException` at run time), and with compatible fields it
would have been a silent miscompile.

Renaming a selectively imported name needs a qualified form for every
kind of item. Records are the one kind with no qualified constructor
under the old rule.

## Decision

1. **Constructors may be qualified.** A record constructor may be
   qualified by its package's path or alias. A union or enum case may be
   qualified by its union, which may itself be qualified: `Shape.Circle`,
   `G.Shape.Circle`, `G.Shape.Empty`.
2. **The written qualifier decides.** A qualified constructor builds the
   type its qualifier names, even when the current package declares a
   same-named record or case. The MSIL backend now resolves a qualified
   path before the local key (`qualifiedRecordCtorKeyMsil`,
   `qualifiedCaseCtorKeyMsil`) at every site that maps a call or value
   to a constructor. The JVM and native backends already did.
3. **The import rule is unchanged.** A qualifier must name a package the
   file can reach (§9.2, #7495). A bare constructor still needs its type
   visible bare.

## Consequences

- docs/01 §2 states the rule. `qualified_ctor_self_test.l` pins it on
  dotnet and the JVM against local records and cases that share
  `Std.JsonValue`'s names.
- #7564 can lower `g` to `P.f` for every kind of item, constructors
  included.
