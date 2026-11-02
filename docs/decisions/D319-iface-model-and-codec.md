# D319 - `Lyric.Iface`: the package interface model, canonical codec and `lyric interface dump` (docs/70 phase 5a, #8612)

**Status:** first slice shipped (header and declaration index). Phase 5a of
docs/70 §13; supersedes docs/45 phases 2-5 as D267 recorded.

## Context

docs/70 §9 replaces contract metadata with a checked package interface that a
consumer loads directly. Phase 5a defines the model, the canonical binary codec,
the dump, the embedding and producer validation. The typed IR's `Ty` (phase 3a)
is not on main yet, and §9.2 says full types are `Ty` with DefPath references.

## Decision

1. **Package `Lyric.Iface`** (`lyric-compiler/lyric/iface/`) holds the model
   (`Iface`, `IfHeader`, `IfDecl`; kinds, visibilities and verification levels
   are unions with stable numeric codes), the codec, the hash and the dump. It
   depends only on `Std.*` and `Lyric.Symbols`, so it identifies declarations by
   the resolver's `DefPath`.
2. **Format.** Magic `LYRI`, a format version (1), one string table in order of
   first use, then the body. Integers are minimal LEB128. The encoder
   canonicalises: declarations sorted by DefPath key, string lists sorted. The
   decoder rejects a bad magic, another version, a padded integer, a count
   larger than the remaining bytes, a non-UTF-8 string, bytes after the body and
   anything not in canonical form, so one interface has exactly one byte image.
   There is no reader for any other version (docs/70 §12.3).
3. **Hash.** The interface hash is the lower-case hex SHA-256 of the canonical
   bytes.
4. **CLI.** `lyric interface dump <file.lyri>` prints the dump and
   `hash: <hex>`. Reading a DLL or JAR follows with the embedding.
5. **Scope of this slice.** Header (package, built-against with hashes,
   verification level, consumer annotations, targets), whole-package re-exports
   and the declaration index. Types, generic parameters and bounds, per-kind
   detail, function signatures, defaults, contracts, bodies, the linkage table
   and hidden exports are left out; no placeholder fields are shipped. Types are
   added on top of 3a's `Ty` once it is on main (`Lyric.Tir`); bodies, defaults
   and contracts need 3a's TIR builder; linkage and hidden exports are 5b.

## Consequences

- The format version is 1 and changes whenever the layout does; every slice
  that adds fields before 5b lands bumps it, since no consumer reads interfaces
  yet.
- Embedding, producer validation (I0005, T0213) and the end-to-end target
  checks follow in the next slices.
