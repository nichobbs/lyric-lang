# D267 - Resolved names, a typed IR and checked package interfaces (docs/70)

**Status:** accepted. Specced in docs/70; implementation phases are docs/70
§13. Supersedes docs/45 phases 2-5 (D098), docs/19 §4 step 2 and §8's "no
per-file visibility scopes" (D180), and the transitive half of D141.

## Context

A compiler review (2026-10, about 85 tracker issues) traced the recurring
"the checker accepts it, a backend rejects, panics or miscompiles it" class,
and names resolving without an import, to five structural causes (docs/70
§1): the checker's types are discarded and four components re-infer them;
`TyError` and `TyVar` equal every type; imported-signature diagnostics are
thrown away; names are filtered at lookup in many places and re-resolved by
each backend, and a multi-file package shares the union of its files'
imports; and a restored library is synthesised back into source and checked
again, without its contracts, ranges, invariants or per-function levels.

## Decision

1. **Imports are per file** (docs/70 §4.1). A package remains the unit of
   declaration, visibility, compilation and interface; one package per file
   and a file-private tier were considered and not adopted. The text merge is
   replaced by a list of separately parsed files with a `FileId` in every
   position. `B0012` is retired.
2. **Transitive visibility is removed** (docs/70 §4.3). A whole import makes
   only the imported package's own `pub` names visible bare, and a qualified
   name may name only a package the file imports. Facades re-export with
   `pub use`.
3. **One resolver binds every name** (`Lyric.Resolve`, docs/70 §4.4) to a
   `SymbolId` interned from a stable `DefPath`, with no unfiltered lookup and
   no empty-origin symbols. Member access is resolved by the checker against
   the receiver type only (§4.5).
4. **No wildcard type** (docs/70 §5): rigid `TyParam`, solving-only
   `TyInfer`, `TyError` constructible only with a diagnostic, T0210 for an
   unsolved type argument, imported signatures checked fatally, unknown
   members an error on every receiver, and an I0001 gate before the middle
   end.
5. **The checker's output is a typed IR** (`Lyric.Tir`, docs/70 §6) with
   every call resolved, arguments ordered with defaults, and every implicit
   operation explicit; `Lyric.Tir.Verify` runs after every pass in CI.
   Declaration expansion (derives, weaving) moves before body checking so its
   output is checked (§7.1); the remaining middle-end passes are TIR to TIR
   (§7.2).
6. **Backends lower TIR and never infer or look up** (docs/70 §8), ported in
   the order native, JVM, MSIL.
7. **A built package carries a checked interface** (`Lyric.Iface`, docs/70
   §9): resolved declarations, contracts, ranges, invariants and
   per-function levels and proof status as data; carried bodies as TIR;
   hidden exports for private helpers that carried code reaches; a
   per-target linkage table; a deterministic binary encoding. No consumer
   re-parses or re-checks a dependency. The old metadata format is not read
   (a deliberate break; ecosystem republished).
8. **Contracts cross packages as data** (docs/70 §10): caller-side
   precondition checks through an exported `__lyric_pre_<f>` entry point that
   reports the caller's site and the callee's clause; postconditions stay
   callee-side; the verifier applies the call rule to imported contracts and
   enforces V0001/V0002 per function.
9. **Plugins are not the contract mechanism** (docs/70 §10.4): static proof
   needs formulas, checking needs signatures before any code runs, and build
   determinism rules out per-call-site queries. A library-specific advisory
   checker plugin point is left open (Q-TIR-005).

## Consequences

Stricter rules land source-fix first, rule second, with releases after
phases 2, 5 and 6 so later phases' seeds carry them (docs/70 §12). Large
deletions follow each phase: the backends' inference and lookup functions,
the span-keyed side tables, the monomorphizer's inferencer, `recheckSpecs`,
`ContractMeta*`, `RestoredPackages` synthesis and the stdlib-from-metadata
path.
