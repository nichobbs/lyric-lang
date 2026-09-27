# D139 — JVM backend: checker-resolved receiver classes, per-package dependency features, transitive `[maven]` (#7378)

**Status:** accepted, implemented

## Context

`lyric-ui`, `lyric-forms` and `examples/ui-customers` (docs/65, D137) shipped
on MSIL only. On `--target jvm` none of their suites compiled (#7378). The
failures fell into three groups, none of them in the libraries:

1. **Erased receivers.** The JVM backend erases generics and tracks static
   types itself, from local annotations and a growing set of heuristics
   (`varGenericArgs`, `elem:` / `fnfield:` registries, `scrutineeGenericArgs`).
   A field read or method call on a receiver those heuristics could not
   type (an element of a generic container, a generic call's result, a
   chain of generic record fields, a match binding of a generic payload)
   was statically `Object` and failed J007. Each earlier fix (#6691, #6708,
   #6957) added one more shape to the heuristics; the next shape failed the
   same way.
2. **Bare-name resolution.** A bare constructor fell back to whichever
   package registered the name first in the bundle, and a bare enum case
   in a pattern could be shadowed by an unrelated non-case type of the same
   name. Both were silent miscompiles (`ClassCastException`, an arm
   compiled as a catch-all).
3. **Dependencies.** On JVM a workspace or path dependency is compiled from
   source into the consumer's bundle. It was erased with the consumer's
   `@cfg` features (so a dependency's `@cfg(feature = "jvm")` kernel was
   dropped), only direct dependencies were bundled, and a dependency's
   `[maven]` artifacts were not on the consumer's classpath.

## Decision

1. **The type checker is the source of receiver types for the JVM backend.**
   The checker records, for every field-access and method-call receiver
   whose type is a record, exposed record, union, opaque or protected type,
   that type's declaring package and name, keyed by the receiver's span
   (`SymbolTable.memberRecvClasses`, the same keying as `callResultTypes`).
   `pipeCheckAndMono` hands the map out through
   `MiddleEndOptions.memberRecvClassesOut`; `Jvm.Bridge` seeds it into the
   file's extern-type map as reserved `~recv~<span>` keys; and
   `Jvm.Codegen.narrowErasedReceiverJvm` checkcasts a receiver that lowered
   to `Object` to that class before member dispatch. The lookup runs only
   where the backend's own tracking produced `Object`, so code that already
   compiled is unchanged. A specialised copy of another package's generic
   drops the keys (its spans belong to another file).
   Distinct types, enums, interfaces and extern types are not recorded: they
   have no class of their own to narrow to.
2. **Bare names resolve in the scope the checker used.** Constructor lookup
   tries the package being generated (or, in a specialised copy, the package
   the generic was written in), then the file's selective imports, then the
   one whole-imported package declaring the name, and only then the
   bundle-wide first registration. A pattern over a scrutinee statically
   known to be an enum tests that enum's case before any union-case lookup,
   and a bare-name hit that is not a union case never suppresses the enum
   test.
3. **A bundled dependency keeps its own features; bundling is transitive.**
   `EmitProjectRequest.packageFeatures` (a list of
   `Lyric.Pipeline.PackageFeatureSet`) names packages erased with their own
   feature set. The CLI fills it for every dependency package it folds into
   a JVM bundle, resolving each dependency's features as a separately built
   dependency's are (#5571): its defaults unless `--no-default-features`,
   plus the root's `--features`, normalized to the target. Dependencies of
   dependencies are bundled too (`collectTransitiveDepSources`).
4. **`lyric restore` propagates `[maven]` transitively** (docs/38 §4) across
   workspace and path dependencies, nearest declaration winning, repositories
   unioned, with a note for each dropped version.

## Alternatives considered

- **Another heuristic per failing shape.** Rejected: that is how the J007
  family grew, and each fix left the next shape broken.
- **A type-ascription rewrite in the middle end** (wrapping receivers in a
  typed local). Rejected: it adds a local per member access on every
  backend and interacts with assignment targets; the span-keyed map changes
  nothing that already compiles.
- **Union of dependency features into the request.** Rejected: features are
  per package (a root's `html` and a dependency's `html` need not mean the
  same thing), and the union weakens the F0013 typo guard.
- **Declaring Undertow in `lyric-ui`'s own `[maven]`.** Rejected: docs/38
  makes `[maven]` a library-author concern, and every consumer of
  `lyric-web` would have had to repeat it.

## Consequences

`lyric-ui` (40 tests), `lyric-forms` (11) and `examples/ui-customers` (14)
pass on both targets. J007 remains as the refusal for a receiver neither the
backend nor the checker can type. `emitter_project_self_test.l`'s
emit-containment test now uses a J009 refusal, since its J007 repro compiles.
