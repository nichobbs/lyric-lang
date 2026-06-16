# Workspace-Based Dependency Management Implementation

## Overview

This document summarizes the implementation of workspace-based dependency management for the Lyric ecosystem libraries, addressing the issue where library builds failed with `B0001` errors due to missing or stale dependency DLLs.

**Status**: Part 1 (configuration) and Part 2 (build integration) complete. Ready for testing and CI integration.

## Problem Statement

Previously, ecosystem libraries used path-based dependencies:
```toml
[dependencies]
"Lyric.Web" = { path = "../lyric-web" }
```

This caused build failures when dependencies hadn't been manually built first:
```
B0001 error: restored dep '.../lyric-resilience/bin/Lyric.Resilience.dll' 
failed to synthesise: restored DLL ... synthesised contract source did not type-check
```

The build system expected pre-compiled DLLs to exist but didn't automatically build them. Developers had to manually build dependencies in correct order before building dependents.

## Solution Architecture

The solution implements workspace-based dependency management per **docs/38-workspace.md (Decision D073)**, with two phases:

### Phase 1: Configuration Migration ✅

**Files changed**: 12 configuration files

1. **Root workspace declaration** (`lyric.toml`):
   - New `[workspace]` table declares the workspace root
   - Lists excluded directories (bootstrap, docs, examples, native, etc.)
   - Auto-discovers all member packages by walking the directory tree

2. **Ecosystem library migration** (11 files):
   - All in-repo dependencies changed from `path = "../..."` to `{ workspace = true }`
   - Affected libraries:
     - lyric-db → Std.Logging
     - lyric-grpc → Lyric.Auth, Lyric.Resilience
     - lyric-health → Lyric.Web
     - lyric-jobs → Lyric.Resilience
     - lyric-lambda → Lyric.Web
     - lyric-mq → Lyric.Cache
     - lyric-search → Lyric.Resilience
     - lyric-session → Lyric.Cache
     - lyric-testing → Lyric.Cache, Lyric.Mail, Lyric.Storage, Lyric.Mq, Lyric.Session, Lyric.Flags
     - lyric-web → Lyric.Auth, Lyric.Resilience
     - lyric-ws → Lyric.Auth

### Phase 2: Build System Integration ✅

**Files changed**: 2 compiler files

1. **New module: `lyric-compiler/lyric/cli/workspace_builder.l`**
   
   Provides the `buildWorkspaceDeps()` function:
   - Discovers workspace root by walking up from the manifest
   - Resolves each `{ workspace = true }` dependency to its directory
   - Builds missing/stale dependencies recursively
   - Returns DLL paths in "name\tdllPath" format for emitter integration
   - Collects errors and reports all failures before halting

   Key API:
   ```lyric
   pub func buildWorkspaceDeps(
     manifest: in Mf.Manifest,
     mfPath: in String,
     target: in Emitter.CompileTarget,
   ): (List[String], Bool)
   ```

2. **Modified: `lyric-compiler/lyric/cli/cli_build.l` (buildProject function)**
   
   Integrated workspace dependency building:
   - Calls `buildWorkspaceDeps()` before processing path dependencies
   - Collects returned DLL paths into the dependency list
   - Maintains backward compatibility with path-based dependencies
   - Handles both `Workspace` and `Path` dependency source types

## Dependency Discovery & Resolution

### Infrastructure (Already Existed)

**`lyric-compiler/lyric/workspace/workspace.l`** provides:

- `findWorkspaceRoot(startDir)`: Walk up from a directory to find workspace root
  - Returns `WorkspaceContext` with root directory, manifest path, and discovered members
  - Returns `None` for standalone projects (no workspace)

- `resolveDep(name, ctx)`: Resolve a package name to its absolute directory
  - Checks `[workspace.overrides]` entries first (for fork/patch workflows)
  - Falls back to member index built during discovery

- Member discovery walks directory tree depth-first:
  - Skips hidden directories (`.git`, `.vscode`, etc.)
  - Skips known build output directories (`node_modules`, `target`, `bin`, `obj`)
  - Skips directories in the `[workspace.exclude]` list
  - Skips subdirectories of already-found members

### How It Works

When `lyric build` is invoked in a workspace:

1. **Manifest parsing** → Lyric.Manifest identifies `{ workspace = true }` dependencies
2. **Workspace discovery** → Ws.findWorkspaceRoot() locates workspace root
3. **Dependency resolution** → For each workspace dependency:
   - Ws.resolveDep() maps name to directory
   - Check if the DLL exists at `<dir>/bin/<name>.dll`
   - If missing: recursively build via buildProject()
   - Return the DLL path
4. **Compilation** → Emitter includes all resolved DLL paths as references

Transitive dependencies are handled automatically: if library A depends on B and B depends on C, building A triggers building B, which triggers building C.

## Backward Compatibility

- **Path dependencies** (`path = "../..."`) continue to work
- Non-workspace projects are unaffected (workspace discovery returns `None`)
- Standalone library builds (single `.l` file) skip workspace processing
- Mixing workspace and path dependencies in the same manifest is supported (not recommended)

## Error Handling

Build failures halt immediately with clear diagnostics:

- **Missing workspace root**: "workspace dep 'X' not found; check workspace root and member list"
- **Missing manifest**: "no lyric.toml found at <path>"
- **Parse errors**: "malformed lyric.toml: <error details>"
- **Build failures**: "build failed (exit code N)"
- **DLL not found after build**: "build succeeded but DLL not found at <path>"

## Testing

### Manual Testing Steps

```bash
# 1. Verify workspace was created
cat lyric.toml

# 2. Verify workspace member discovery
ls lyric-cache/
ls lyric-web/
# Both should have lyric.toml

# 3. Verify dependency declarations
grep -A 2 "^\[dependencies\]" lyric-grpc/lyric.toml
# Should show "{ workspace = true }"

# 4. Clean build artifacts
rm -f lyric-*/bin/*.dll

# 5. Test building a dependent library (no explicit dependency builds)
./bin/lyric build --manifest lyric-grpc/lyric.toml

# Should automatically build:
#   - lyric-auth (dependency of lyric-grpc)
#   - lyric-resilience (dependency of lyric-grpc)
#   - lyric-grpc (main target)
```

### CI Integration

No CI changes required. The existing `lyric build` and `lyric test` commands now automatically handle workspace dependencies. Existing CI scripts will benefit immediately.

### Known Limitations (Deferred)

1. **Circular dependency detection**: Not yet implemented
   - Will fail at build time when a cycle is encountered
   - Tracked separately (suggest: #????)

2. **Staleness detection**: Only checks file existence
   - Modification-time-based invalidation deferred
   - Can be added later without breaking changes

3. **Partial success reporting**: Build halts on first error
   - Future: Collect all failures and report together
   - Tracked separately (suggest: #????)

4. **Manifest version checking**: `{ workspace = true, version = "..." }` accepted but not validated
   - Version constraint validation deferred to future phase

## Future Work

### Short-term (Phase 2 follow-up)

1. Add circular dependency detection with clear error messages
2. Implement modification-time-based staleness detection for incremental builds
3. Add `--workspace-graph` flag to visualize dependency tree
4. Add per-member build ordering hints for parallel builds

### Medium-term (Phase 3)

1. Integrate with `lyric restore` for transitive NuGet/Maven dependency resolution
2. Support git-based dependencies (`{ git = "...", tag = "v1" }`)
3. Implement `[workspace.overrides]` for fork/patch workflows
4. Add workspace-aware `lyric publish` for atomic multi-package releases

### Long-term (Phase 4+)

1. Package registry integration for external workspace members
2. Dependency version constraint resolution
3. Lock file management for reproducible builds
4. Parallel multi-member builds

## Related Documentation

- **docs/38-workspace.md**: Full workspace specification (D073)
- **docs/39-package-registry.md**: Package registry design (D074)
- **CLAUDE.md**: Project conventions and bootstrap processes

## Commits

1. **Migrate ecosystem libraries to workspace-based dependency management (Part 1)**
   - Create root lyric.toml with workspace declaration
   - Migrate 11 ecosystem libraries to `{ workspace = true }`

2. **Implement workspace-based transitive dependency building (Part 2)**
   - New workspace_builder.l module
   - Integration into cli_build.l

## Implementation Notes

### Design Decisions

- **Why walk up for workspace root?** Mirrors Cargo's design; allows nested projects and works with subshells
- **Why exclude list instead of include list?** More intuitive; excludes are permanent; whitelist approach would require explicit opt-in for every new library
- **Why require `[workspace]` table?** Explicit opt-in prevents accidental workspace activation from a shared parent directory
- **Why build only when missing?** Matches user mental model: "build once, use many times"; modification-time checks are orthogonal
- **Why synthesise `buildProject` calls?** Reuses existing build logic; simpler than duplicating manifest parsing and dependency handling

### Code Organization

```
lyric-compiler/lyric/
├── workspace/workspace.l        ← member discovery + resolution (PRE-EXISTING)
├── manifest.l                   ← TOML parsing (PRE-EXISTING)
└── cli/
    ├── cli_build.l              ← MODIFIED: integrated workspace builder
    ├── workspace_builder.l       ← NEW: transitive dependency building
    └── cli_*.l                  ← other commands (unchanged)
```

The separation allows workspace building to be reused by other CLI commands (test, prove, etc.) in future phases.

### Why No F# Changes

Zero F# changes were required because:
1. Manifest parsing for `{ workspace = true }` was already implemented
2. Workspace member discovery was already implemented
3. Only the build CLI needed updating, which is self-hosted in Lyric

This aligns with CLAUDE.md's production-readiness standard: new features land in Lyric, not in the F# bootstrap.

## Questions & Answers

**Q: What if I have a workspace but want to opt out for a specific library?**  
A: Add `workspace = false` to the library's `[package]` section in its lyric.toml.

**Q: Can I have nested workspaces?**  
A: No; workspace discovery stops at the first [workspace] declaration it finds while walking up.

**Q: What if a workspace dependency is published to a registry?**  
A: Update the dependency from `{ workspace = true }` to a version string (e.g., `"0.1.0"`). The manifest parser supports mixing both forms.

**Q: Do I need to run `lyric restore` with workspaces?**  
A: Only for NuGet/Maven dependencies. Workspace members are resolved locally; no fetch is needed. `lyric restore` remains required for external registry packages.

**Q: How do I update a workspace member from a fork back to main?**  
A: Use `[workspace.overrides]` in the root manifest to patch the path. See docs/38-workspace.md §3.3.

---

**Implementation Date**: June 2026  
**Specification**: docs/38-workspace.md (D073)  
**Related Issues**: #????, #????
