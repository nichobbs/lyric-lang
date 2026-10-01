# D156 — Native graphics: resolutions of Q-GFX-005 to Q-GFX-010

**Status:** accepted

Resolves the remaining open questions of `docs/67-native-graphics-plan.md`
§10, after D155 resolved Q-GFX-001 to Q-GFX-004.

## Decision

1. **Q-GFX-005: the marker is named `Plain`, with the rules D155 item 3
   gives.** Lyric enums have no explicit ordinals, so the question of
   whether such enums qualify does not arise; C enums reached through
   `lyric bindgen` become integer constants in kernel files, not Lyric
   enums.

2. **Q-GFX-006: `lyric bindgen` reads both `webgpu.yml` and clang's JSON
   AST.** `webgpu.yml` (from `webgpu-native/webgpu-headers`) is the
   source the C header is generated from and carries more than the header
   does (ownership, optionality, callback shapes), so it drives the WebGPU
   binding. `clang -Xclang -ast-dump=json` drives every other C library
   (SDL3, FreeType, HarfBuzz, AccessKit).

3. **Q-GFX-007: native libraries come from prebuilt archives by default.**
   `lyric restore` fetches an archive per target triple with its SHA-256
   checksum in the lock file, so a fresh machine builds without system
   packages. A `[native]` library entry may opt into `pkg-config` instead,
   for distribution packaging.

4. **Q-GFX-008: records have value semantics on every backend.** This is
   what `docs/01` §2.4 already says ("records are value types"); it is now
   explicit about mutation:
   - After `var p = q; p.x = 1`, `q` is unchanged. The same holds for
     passing a record as an argument, returning it, storing it in a field
     or collection, and capturing it in a closure or `spawn`.
   - A copy includes record-typed fields recursively. Fields of reference
     type (`List`, `Map`, `Set`, closures, protected types, extern
     objects) are copied as references, as `.copy()` already specifies.
   - A record with no `var` field anywhere in its record-typed fields is
     immutable, so sharing its storage is unobservable. Backends may
     share such records freely; only records that can be mutated need a
     physical copy.

   Any backend on which a mutation shows through another binding has a
   bug. Phase G1 audits each backend and fixes the divergences. Code that
   relied on the sharing behaviour changes meaning, which is accepted:
   it contradicted the specification.

5. **Q-GFX-009: the Windows port (G9) starts as soon as G3 lands,** in
   parallel with G4 to G7, rather than after the sample game.

6. **Q-GFX-010: `lyric-game` has no entity-component system.** It stays a
   frame loop, input and asset layer. An ECS, if wanted, is a separate
   library over `buffer[T]`, considered after the G7 sample game.
