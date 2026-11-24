# The builder lifts only the qualified-package rule for the checker's own annotations (docs/70 phase 3a, #8613)

**Status:** shipped; the checker's symbol table and the TIR builder. Corrects D769.

## Context

D769 let the builder resolve an annotation the checker spelled by package (`Ui.Core.Prop`, for a type the file does not import) by lifting the symbol table's import rule around `resolveType`. The import rule also decides how a **bare** name resolves: with it lifted, the resolver's answer is replaced by the scope-priority scan, which can pick another declaration of the same name. On the #9282 branch the compiler bundle failed with I0003 in `plugin_tools/plugin_manifest.l` (`checkPayload`, `checkManifestText`, the payload checks): `val fields = match v { case JObject(fs) -> fs; ... }` was annotated `List[JsonField]`, and the bare `JsonField` resolved to a different declaration (#805) than the one the union case carries (#261).

## Decision

The symbol table holds a separate switch, `qualifiedRuleLifted`, read only by `checkQualifiedTypePackageRef` (the T0020 reachability check of a qualified type path). `annotatedTy` raises it for the duration of its `resolveType`; the import rule itself, and so the resolution of every bare name, is untouched. `symTableLiftImportRule` and `symTableRestoreImportRule` are removed.

## Consequences

`reportViewports` (D769) still builds, and the compiler bundle's `plugin_manifest.l` bodies verify again. Test: `scripts/ci/tir-builder-shapes-e2e.sh` (`unimported_type_in_open_join`, unchanged) for the qualified spelling; the compiler bundle build under the gate for the bare one.
