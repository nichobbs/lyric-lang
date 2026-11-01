# D309 — A bare enum case no visible package declares is T0222 on every backend (#8667)

**Status:** shipped

## Context

A bare enum case (`Error`, no `Enum.` prefix, no expected enum type) is resolved
by scope: the current package's own enum with that case, then an enum of a
package the file imports. When several enums declare the case and neither tier
finds one, the MSIL backend fell back to the first registered enum
(`resolveBareEnumCaseOrdinalByScope`), the JVM to the first registered
`enumcase:<Case>` signature, and native to the first `enumDefs` entry. Registration
order differs between a bundle and its restored dependencies (the standard
library's enums register before a restored package's), so the fallback read
`Std.File.EntryKind.Other` for a restored `Category.Other` (#8648), with no
diagnostic.

A survey (#8667) ran a compiler instrumented at the MSIL fallback over every
project in this repository (102 manifests) and over all 73 nichobbs/cloud-agents
entries: it was reached zero times. A bare case whose enum is visible only
through an aliased import is rejected by the checker (T0020), and a case
re-exported through `pub use` is resolved by codegen's hints before the
fallback. So no existing program changes.

## Decision

The fallback becomes a build error, **T0222**, on all three backends:

> ambiguous enum case 'Error' in package 'App': it is declared by A.Mood,
> B.Sev, and none of those enums is declared in this package, imported by it,
> or named by an expected type ...

It fires only when the case is declared by two or more distinct enums and no
tier before the fallback resolved it. A case only one enum declares, or one
resolved by the current package, an import or an expected type, is unchanged.

- **MSIL:** a positioned `Diagnostic` on `CodegenCtx.diagnostics` (the F0021-F0025
  convention), so `Msil.Bridge` fails the build after codegen and every
  occurrence is reported.
- **JVM:** `collectFileSigsSeeded` records `enumcaseambig:<Case>` (its owner lists
  the declaring enum classes) when a second enum claims the bare key, and
  `importAwareRegistry` records `enumcasevis:<Case>` in a file's registry when
  its own package or an import declares the case. `ambiguousBareEnumCaseJvm`
  refuses the bare fallback when the first marker is present and the second is
  not; the emitter boundary passes an `error[T0...]` panic through verbatim.
- **Native:** `Ctx.enumDefs` carries `<Case>.__bareambiguous` when a second enum
  claims the bare key, and `resolveBareEnumCase` resolves the case in the current
  package, then its imports, then reports the declaring enums. This also makes a
  bare case in an ambiguous bundle prefer the referencing package's own and
  imported enums, as MSIL and the JVM already did, instead of the first
  registered.

The code is T0222 (the next free `T` number after T0221) because the condition is
a name-resolution failure the type checker normally catches, as T0115 is for a
qualified reference.

## Consequences

- No existing program changes (survey above). A future checker/codegen
  disagreement is a build error rather than a wrong ordinal.
- The checker rejects such references first, so no source program reaches T0222
  today. Coverage is below the CLI: `msil_bare_enum_case_guard_self_test.l`
  (MSIL), `enum_case_collision_self_test.l` (JVM and native resolvers) and a
  native two-package program in `llvm_project_self_test.l`.
- Also fixed: a union case named `Unit` made the JVM resolve the `Unit` return
  type through the constructor registry (`recordRetClassOfBundleTe`), so every
  `Unit` call `checkcast` a void result (J008, #8652 item 4). Reserved type
  keywords now win over constructor names there
  (`union_case_named_unit_self_test.l`, both targets).
