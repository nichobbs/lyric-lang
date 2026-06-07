# 45 — Contract Metadata Direct Resolution

**Status**: Proposal (ready for decision)

## Problem

Currently, when a consumer builds against a restored Lyric dependency:

1. **Load contract JSON** from the DLL resource
2. **Synthesize to Lyric source** (concatenate `repr` strings)
3. **Re-parse** with `Lyric.Parser.parse`
4. **Re-type-check** with `Lyric.TypeChecker.check` (+ preamble for sibling types)
5. Extract symbol table for downstream use

This synthesis → parse → check cycle is **duplicated for every consumer** importing the same library. For bundled DLLs with multiple packages, each package's synthesis is consumer-specific (preamble depends on which other packages are loaded). This creates unnecessary per-consumer overhead.

Meanwhile, the auto-FFI approach for external types (BCL/JVM) reads metadata directly and threads signatures into symbol tables without synthesis/parse/recheck.

## Design Decision

Migrate to **metadata-direct symbol table construction** for restored Lyric packages, mirroring the auto-FFI pattern:

1. **Explicit visibility in metadata**: Add a `visibility` field to `ContractDecl` so visibility is structured, not parsed from `repr`.

2. **Dependency manifest**: Embed a manifest of direct dependencies' contract metadata in each DLL so consumers can load transitive dependencies without preambles.

3. **Direct symbol table construction**: Build `Symbol` entries directly from contract JSON (no synthesis/parse/recheck).

4. **Single validation point**: Validate metadata consistency once at library-build time; consumers trust the compiled form.

## Rationale

### Performance
- Eliminates per-consumer synthesis/parse/check overhead
- Consumers that import multiple restored packages avoid redundant work
- Especially beneficial for bundled DLLs (no preamble reconstruction needed)

### Simplicity
- Removes the sibling-reference / preamble complexity
- Direct JSON → symbol table is simpler than synthesize → parse → check → symbol table
- One-time validation at build time, not per-consumer

### Safety
Visibility guarantees are **preserved and strengthened**:
- Current: visibility is encoded in `repr` string; extracted during re-parse
- Proposed: visibility is explicit metadata; no re-parse needed
- The type-checker's `checkImportedVisibility` still enforces the rule
- Visibility is now structured, not string-derived, reducing parsing errors

### Consistency with auto-FFI
The approach mirrors how the compiler handles external types (`System.Math`, JDK types): read metadata once, build signatures, trust the compiled form. Reduced work, same safety.

## Alternatives Considered

| Alternative | How it works | Pros | Cons | Why rejected |
|---|---|---|---|---|
| **Status quo (synthesize per consumer)** | Keep current synthesis → parse → recheck cycle | Validates each consumer; reuses existing code | Duplicated work per consumer; slow for bundled DLLs | Performance bottleneck; doesn't scale |
| **Cache synthesis results** | Synthesize/parse/check once at library build; cache result in DLL | Eliminates per-consumer re-work | Preambles are consumer-specific (different for each consumer); cache format adds complexity | Can't pre-compute preambles; doesn't solve sibling references |
| **Binary AST serialization** | Emit parsed AST in a binary format; deserialize at load time | Faster than re-parsing | Requires AST serialization format; breaks on parser changes; adds versioning complexity | Simpler to stay with metadata + on-demand symbol table |
| **Pre-compiled symbol tables** | Emit SymbolTable directly as binary blob | No parse/check overhead | Requires symbol table serialization; couples library format to compiler; version brittleness | Metadata-direct is more flexible and cleaner |
| **Lazy type resolution** | Don't resolve types upfront; resolve on-demand as encountered | Minimal upfront work | Complex to implement; ordering issues with preambles; harder to debug | Over-engineered for this problem |
| **Explicit type exports (like C headers)** | Emit actual compiled type definitions consumers link against | Traditional model; robust | Loses contract abstraction; visibility control weak; increases binary size | Incompatible with Lyric's contract-based design |

## Changes Required

### 1. Metadata Format (breaking change — format version bump)

**File**: `lyric-compiler/lyric/contract_meta.l`

Add `visibility` field to `ContractDecl`:

```lyric
@stable(since = "0.1")
pub record ContractDecl {
  kind: String
  name: String
  repr: String
  visibility: String              // NEW: "pub" | "internal" | "" (package-private)
  isPure: Bool
  stability: String
  requiresClauses: List[String]
  ensuresClauses: List[String]
  body: Option[String]
  params: List[ContractParam]
}
```

Add `dependencies` field to `Contract` and include contract hash for integrity:

```lyric
pub record Contract {
  packageName: String
  version: String
  level: String
  formatVersion: Int              // bump to 3 (v2 support dropped immediately)
  decls: List[ContractDecl]
  dependencies: List[ContractDependency]  // NEW: transitive deps metadata
  contractHash: String             // NEW: SHA256 hash of this contract's JSON
}

pub record ContractDependency {
  packageName: String
  version: String
  contractHash: String             // SHA256 hash of the dependency's contract
}
```

### 2. Contract Metadata Emitter (self-hosted only)

**File**: `lyric-compiler/lyric/contract_meta_emit.l` (new `Lyric.ContractMetaEmit` package)

Per CLAUDE.md "No new F# code" policy, all implementation is in Lyric. When emitting a contract (called by the bridge):

1. Extract `visibility` from each declaration's parsed `Visibility` field
2. Populate the `dependencies` list by scanning the `EmitRequest`'s resolved packages
3. Emit the enhanced contract JSON with format version 3 and contractHash

The F# bootstrap emitter (`ContractMeta.fs`) is left untouched unless stage-0 to stage-1 bootstrap cannot complete; any such change would be a bootstrap-continuity fix, not a planned feature.

### 3. Restored Packages Loader

**File**: `lyric-compiler/lyric/restored_packages.l`

Refactor into two entry points:

```lyric
/// Load a restored package's contract and build symbol table directly.
/// No synthesis/parse/recheck; direct JSON → symbol table.
pub func loadRestored(dllPath: in String): Result[RestoredArtifact, RestoredLoadError]

/// Build symbol table entries directly from a Contract.
/// Validates visibility and handles transitive dependency references.
func buildSymbolTable(
  contract: in Meta.Contract, 
  dependencyArtifacts: in List[RestoredArtifact]
): Result[SymbolTable, RestoredLoadError]
```

### 4. Bridge Integration

**File**: `lyric-compiler/lyric/emitter.l` and `lyric-compiler/jvm/bridge.l`

When building a consumer:

1. **Load the main package's contract** from restored DLL
2. **Load transitive dependencies** using the embedded dependency manifest
3. **Build symbol tables directly** (no preambles, no re-check)
4. **Thread into `CodegenCtx`** as before
5. **Skip the synthesis/parse/recheck cycle entirely**

```lyric
// Pseudo-code
val art = loadRestored(dllPath)  // One JSON read, direct symbol table
val symtbl = buildSymbolTable(art.contract, art.dependencies)
// Thread symtbl into CodegenCtx
```

## Validation and Safety

### What's validated at library-build time?
- Contract metadata format is well-formed JSON
- Each declaration's `repr` is parseable (synthesize once, validate, store only `repr`)
- Visibility is extractable from the parsed source
- Dependencies list is complete and correct

### What happens at consumer-build time?
- **No parsing or type-checking of the contract** (trust library's validation)
- **Load and resolve transitive dependencies** (verify the dependency chain is available)
- **Build symbol tables** and thread into compiler (same as current)
- **Visibility check** (`checkImportedVisibility`) still applies when the consumer resolves symbols

### What breaks if metadata is wrong?
- Malformed JSON: caught at library build (not propagated to consumers)
- Wrong visibility: consumer's type-checker catches T0097 (same as today)
- Missing dependency: `RestoredLoadError::DependencyMissing` (cleaner than preamble validation failure)
- Contract hash mismatch (if using integrity checks): caught at load time

## Trade-offs

| Aspect | Current | Proposed |
|--------|---------|----------|
| Per-consumer cost | High (synthesis + parse + check each time) | Low (direct load + symbol table build) |
| Validation timing | Per-consumer (every build) | Once at library build |
| Format change | None | format version 3 (breaking) |
| Complexity | Medium (preamble logic in restored_packages.l) | Lower (direct symbol table construction) |
| Trust model | Validated per consumer | Trusted from library |
| Cross-package refs | Preamble reconstruction | Explicit dependency manifest |

## Migration Path

**v2 support is dropped immediately** — breaking change in one release.

Per CLAUDE.md "No new F# code" policy, all implementation is in Lyric (`lyric-compiler/lyric/`):

1. **Phase 1**: Implement `lyric-compiler/lyric/contract_meta_emit.l` (`Lyric.ContractMetaEmit` package). Adds visibility extraction from parsed `Visibility` field, dependency list population, and v3 JSON emission with contractHash.

2. **Phase 2**: Update emitter bridge to call `Lyric.ContractMetaEmit` to produce v3 contracts. The F# bootstrap emitter is only touched if stage-0 to stage-1 bootstrap cannot complete without it; that change would be justified as a bootstrap-continuity fix, not a planned feature.

3. **Phase 3**: Implement direct symbol table builder in `restored_packages.l` (no synthesis/parse/recheck)

4. **Phase 4**: Migrate bridge to use direct loader

5. **Phase 5**: Remove synthesis-based loader and temporary v2 compat code

**Publish guidance**: Users publishing libraries must rebuild with the new compiler to emit v3 contracts. The CLI will reject v2 contracts with a clear error message.

**Consumer requirement**: All consumers must upgrade to a compiler version that reads v3 contracts.

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| **Breaking change (v2 → v3 immediate)** | Clear error message guides users to rebuild; publish release notes with detailed migration steps; tooling can warn early if a library hasn't been rebuilt |
| **Trust model shift (fewer per-consumer checks)** | Contract hash for integrity checking; rigorous validation at library-build time; consider optional signature-based verification for published libraries |
| **Complexity in direct symbol table builder** | Write thorough tests; mirror symbol-building logic from current parse/check path; validate parity with old approach via round-trip testing |
| **Transitive dependency resolution bugs** | Embed full dependency metadata chain; validate completeness at library build; hash mismatch catches corrupted/out-of-sync dependencies |
| **Tooling ecosystem needs update** | Package managers and build tools must understand the new format; coordinate release with documentation |

## Decisions Made

**D1 — Metadata-direct symbol table construction**: Chosen over alternatives (see "Alternatives Considered"). Faster, simpler, consistent with auto-FFI.

**D2 — Contract hash required**: Include SHA256 hash of each contract (and each dependency) for integrity checking. Required, not optional.

**D3 — v2 support dropped immediately**: Breaking change. Users must rebuild libraries with the new emitter in the next release. Clear error messages guide users.

**D4 — Explicit visibility field**: Required in metadata format. No string-parsing.

**D5 — New fields are stable**: The `visibility`, `dependencies`, and `contractHash` fields can carry `@stable(since = "0.1")` because they are metadata-only, not part of the runtime API surface.

**D6 — v2 rejection error message**: When the CLI encounters a contract with `formatVersion` less than 3, it must emit: `"Contract metadata format v2 is no longer supported. Rebuild the library with the latest compiler and re-publish."` No dual-path support; no compatibility routing.

## Open Questions

**Q1**: When a consumer loads a bundled DLL with multiple packages, should we flatten the dependency manifests into one combined list, or keep them per-package? (Propose: keep per-package, merge at load time for clarity.)

## References

- **Current contract system**: `docs/08-contract-semantics.md`, `docs/01-language-reference.md` §3.3
- **Restored packages** (synthesis-based): `lyric-compiler/lyric/restored_packages.l`
- **Auto-FFI** (direct metadata): `lyric-compiler/jvm/auto_ffi.l`, `bootstrap/src/Lyric.Emitter/Msil.Bridge.fs`
- **Contract emission**: `bootstrap/src/Lyric.Emitter/ContractMeta.fs`

## Implementation Notes

- **Visibility extraction**: parse the first keyword in `repr` (e.g., `"pub func foo"` → `"pub"`, `"record Bar"` → `""`)
- **Dependency manifest**: list of `{packageName, version, contractHash}` serialized as JSON (contractHash is required)
- **Symbol table builder**: adapt the logic from `typechecker_symbols.l::registerItem`, but ingest from metadata instead of parsed AST
- **No v2 compatibility shim**: The emitter immediately rejects v2 contracts with a clear error message directing users to rebuild and republish. No dual-path support.

