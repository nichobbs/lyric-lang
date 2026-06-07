# 42 — Contract Metadata Direct Resolution

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

Add `dependencies` field to `Contract`:

```lyric
pub record Contract {
  packageName: String
  version: String
  level: String
  formatVersion: Int              // bump to 3
  decls: List[ContractDecl]
  dependencies: List[ContractDependency]  // NEW: transitive deps metadata
}

pub record ContractDependency {
  packageName: String
  version: String
  // Optional: hash of the dependency's contract for integrity checking
  contractHash: Option[String]
}
```

### 2. Emitter (both F# bootstrap and self-hosted)

**File**: `bootstrap/src/Lyric.Emitter/ContractMeta.fs` and `lyric-compiler/lyric/contract_meta_emit.l`

When emitting a contract:

1. Extract `visibility` from each declaration's parsed `Visibility` field
2. Populate the `dependencies` list by scanning the `EmitRequest`'s resolved packages
3. Emit the enhanced contract JSON with format version 3

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

1. **Phase 1**: Add format version 3 support to the metadata parser (backwards-compatible, read v2 and v3)
2. **Phase 2**: Update the F# bootstrap emitter to emit format v3 (with visibility + dependencies)
3. **Phase 3**: Implement direct symbol table builder in `restored_packages.l`
4. **Phase 4**: Migrate bridge to use direct loader (remove synthesis/parse/recheck)
5. **Phase 5**: Deprecate and remove synthesis-based loader (once all libraries are v3)

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Format version bump requires re-emit of all published libraries | Gradual deprecation (v2 support continues for one cycle); encourage early adoption with release notes |
| Trust model shift (fewer per-consumer checks) | Validation at library-build time is more rigorous; add optional contract hash to manifest for integrity |
| Complexity in direct symbol table builder | Write thorough tests; mirror the symbol-building logic from the current parse/check path |
| Transitive dependency resolution bugs | Embed full metadata chain (not just direct dependencies); validate completeness at library build |

## Open Questions

**Q1**: Should we compute and embed a hash of each contract to detect corruption or tampering? (Optional; improves integrity checking at load time.)

**Q2**: When a consumer loads a bundled DLL with multiple packages, should we flatten the dependency manifests into one combined list, or keep them per-package? (Propose: keep per-package, merge at load time for clarity.)

**Q3**: Should format v2 support be dropped immediately or maintained for one release cycle? (Propose: maintain for one cycle, deprecation warning, then drop.)

**Q4**: Can we add a `@stable(since = "0.1")` on the new fields so they're part of the stable ABI surface? (Yes; they're metadata-only, not part of the runtime API.)

## References

- **Current contract system**: `docs/08-contract-semantics.md`, `docs/01-language-reference.md` §3.3
- **Restored packages** (synthesis-based): `lyric-compiler/lyric/restored_packages.l`
- **Auto-FFI** (direct metadata): `lyric-compiler/jvm/auto_ffi.l`, `bootstrap/src/Lyric.Emitter/Msil.Bridge.fs`
- **Contract emission**: `bootstrap/src/Lyric.Emitter/ContractMeta.fs`

## Implementation Notes

- **Visibility extraction**: parse the first keyword in `repr` (e.g., `"pub func foo"` → `"pub"`, `"record Bar"` → `""`)
- **Dependency manifest**: list of `{packageName, version, contractHash?}` serialized as JSON
- **Symbol table builder**: adapt the logic from `typechecker_symbols.l::registerItem`, but ingest from metadata instead of parsed AST
- **Backwards compatibility**: while v2 is supported, the bridge can detect format version and route to either loader (synthesize for v2, direct for v3)

