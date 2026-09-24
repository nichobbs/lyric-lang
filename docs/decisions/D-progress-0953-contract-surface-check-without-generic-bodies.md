# D-progress-953 — Restored-contract surface check renders functions without bodies

**Status:** shipped

## Problem

Since #6363 a restored Lyric package's contract metadata carries the bodies
of its generic functions so a consumer can specialise them. When a consumer
loads such a DLL, `Lyric.RestoredPackages.synthesiseArtifact` renders the
contract back to source and type-checks it standalone to validate the
package's surface. That synthesised file has no imports, but the spliced
generic bodies still referred to every stdlib or sibling-package name the
package used (`None`, `newList`, an imported union case). The standalone
check therefore failed with "unknown name 'None'" and the consumer could
not build against any library whose generic functions touch imported
names, although the library itself type-checked with its real imports.

## Decision

- `synthesiseSourceWith(contract, preamble, withBodies)` renders every
  function either with its spliced generic body or as its bodyless
  signature. `synthesiseSource` keeps its behaviour (`withBodies = true`).
- The standalone re-typecheck in `synthesiseArtifact` uses the bodyless
  rendering: it validates the package's surface (signatures, types,
  contracts), which is what it exists to check. The bodies were already
  checked when the library was compiled.
- The source stored on the artifact for consumer-side specialisation still
  carries the bodies, so imported-generic monomorphisation is unchanged.
- Preamble declarations from sibling packages always render bodyless.

## Verification

`restored_packages_self_test.l` gains
`testSynthesiseArtifactGenericBodyUsesImportedNames`: a generic function
whose body uses `None` and `newList` synthesises without diagnostics, and
the stored source still contains its body.
