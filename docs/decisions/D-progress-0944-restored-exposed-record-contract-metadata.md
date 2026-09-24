# D-progress-944 — restored `exposed record` round-trips through contract metadata (#6533)

**Status:** shipped

**Context.** A restored (cross-package/`[dependencies] path`) `exposed record`,
plain or generic, was entirely unusable by a downstream consumer: the
consumer's type check failed with `error[T0020] ... unknown name 'Point'`
before codegen ever ran. Root cause: `Lyric.ContractMeta.buildContractFromFile`
(both its `pubTypeNames` pre-pass and its main item-to-`ContractDecl` walk)
matched `IRecord` but never `IExposedRec` — an `exposed record` item was
silently dropped from the producer's emitted contract metadata entirely, so
a consumer's re-synthesised source never even declared the type.

`pipeAddCrossPackageItems`/`pipeIsCrossPackageItem` (the shared
cross-package symbol-table builder both backends' type checkers consult)
already includes `IExposedRec` when building a symbol table directly from a
`SynthesisedArtifact.source` — that path was never the gap. The gap was
specifically in how contract metadata gets the item there in the first
place.

**Fix.** Threaded an `isExposed: Bool` parameter through
`reprForRecord` (`lyric-compiler/lyric/contract_meta.l`): the rendered head
is `"pub " + (exposed if isExposed) + "record " + name + ...` instead of an
unconditional `"pub record "`. Since `docs/grammar.ebnf` §3.4 already
accepts `pub exposed record Name { ... }` as ordinary re-parseable item
syntax, and every `ContractDecl.repr` is spliced back as literal source
text and re-parsed (`renderDecl`, `lyric-compiler/lyric/restored_packages.l`),
this needed **no new JSON kind discriminator or boolean field** on
`ContractDecl` — baking the keyword into the existing `kind = "record"`
repr text is sufficient, avoiding a contract-metadata format-version bump
entirely. Added the matching `IExposedRec(r) -> ...` arms to both of
`buildContractFromFile`'s item-kind matches, calling `reprForRecord(r,
isExposed = true)`.

On the codegen side, `Msil.Codegen.registerRestoredMembers`'s item-kind
match (`lyric-compiler/msil/codegen.l`) had the same gap one level down: an
`IRecord` arm calling `registerRestoredRecordCtor`/`registerRestoredRecordFields`/
`registerRestoredRecordBodyMethods`, but no `IExposedRec` arm — so even
once the metadata fix lets the reconstructed source correctly parse the
item as `IExposedRec` (not silently coerced to `IRecord`), codegen's own
per-item dispatch would still skip it. Added the missing `IExposedRec` arm,
identical to the `IRecord` one (both wrap the same `RecordDecl` shape; a
producer's `exposed`-ness only affects reflection-visibility in the
producer's own compiled assembly, not how a consumer constructs/reads it).

JVM parity was flagged as unchecked by the original issue and remains
unchecked here: the `Lyric.ContractMeta`/`Lyric.RestoredPackages` fix is
backend-shared (both `Msil.Bridge` and `Jvm.Bridge` consume the same
`SynthesisedArtifact`), so the type-checking-level gap this entry fixes is
almost certainly the same fix for JVM too, but JVM's own codegen path
resolves restored-type dispatch by real classfile name/descriptor rather
than through an equivalent token-registry step, so it may not need an
`IExposedRec`-specific codegen arm the way MSIL did — not independently
verified with a JVM-target regression test in this pass.

**Verification.** New tests in `msil_restored_bridge_self_test.l` ("restored
plain exposed record constructs and reads fields (#6533)" and "restored
generic exposed record constructs and reads its field (#6533)") reproduce
the issue's exact repro shapes (`pub exposed record Point { x: Int, y: Int
}` and `pub exposed record Box[T] { value: T }`) through the real
two-assembly restored-dependency harness, asserting real field values
round-trip. `msil_restored_bridge_self_test.l`: 8/8 pass (was 6/6).
`contract_meta_self_test.l`: 43/43 pass (unaffected). `restored_packages_self_test.l`:
23/23 pass (unaffected).

**Related:** #6533 (fixed by this entry), #6526/#6527/#6528/#6530/#6529/#6532
(the three prior in-bundle `IExposedRec`-registration-gap fixes this same
session's investigation cites as the established pattern for this class of
fix), `docs/45-contract-metadata-direct-resolution.md` (contract metadata
design).
