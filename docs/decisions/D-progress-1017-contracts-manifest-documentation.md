# D-progress-1017 — Documentation for `[contracts]` manifest table

**Closes:** #7640

**Resolves:** docs/63 Q-BP-009 — does `contractsEnabled` gate system-level checks?

## Summary

The `[contracts]` manifest table controls whether the compiler synthesizes runtime checks for user-level contract clauses (`requires:`/`ensures:`/`invariant:`). This decision documents the table, clarifies the scope (user-level checks only), and updates project documentation to reflect the shipped feature.

## What is `[contracts]`?

```toml
[contracts]
enabled = true   # default: true
```

When `enabled = false`, the compiler:
- Parses and type-checks all contract clauses normally
- Does NOT synthesize runtime `assert(...)` statements for user-level `requires:`/`ensures:` clauses
- Still synthesizes runtime checks for system-level structural invariants: parameter range checks, return-type range checks, protected-type invariants, and loop invariants

The reason for this split:

- **User-level checks** (`requires:`/`ensures:`) are assertions about the *application's* state and the contract the function author intended. In production after offline verification, they may be disabled for performance.
- **System-level checks** (range subtypes, protected-type invariants, loop invariants) enforce Lyric's *type safety* guarantees. These must always run, regardless of `contractsEnabled`, or the type system would be unsound.

Language reference documentation (§3.7) and book chapter examples make this distinction explicit. Proof obligations for `lyric prove` are unaffected by the manifest setting.

## Implementation details

The self-hosted contract elaborator (`Lyric.ContractElaborator`) gates user-level contract synthesis by:

1. Always prepending system-level range checks for parameter/return types (never gated)
2. Conditionally collecting user-level `requires:` clauses only when `contractsEnabled` is true
3. Conditionally collecting user-level `ensures:` clauses only when `contractsEnabled` is true
4. Always including system-level protected-type invariants (never gated)

Loop `invariant:` clauses are always synthesized as runtime checks at loop iteration points; the gating applies only to whether `requires:` and `ensures:` contract clauses are checked.

## Documentation updates

Per CLAUDE.md conventions, documentation spans three surfaces:

- **Language reference** (`docs/01-language-reference.md` §3.7): Added new section "Contract compilation — `[contracts]`" describing the table, its fields, defaults, and semantics. Cross-references the verification chapters (§6.4 and Chapter 17).
- **Book** (`book/chapters/01-getting-started.md`): Added "Contract checking — `[contracts]`" subsection after "Build profile and output shape" to align with manifest configuration topics. Explains the table, TOML example, and use case (production optimization after formal verification).
- **Bootstrap progress** (`docs/10-bootstrap-progress.md`): Added status table row marking the `[contracts]` manifest table as shipped.
- **Open questions** (`docs/63-build-profiles-and-debugger.md`): Resolved Q-BP-009 ("does `contractsEnabled` gate system-level checks?") — it does not; only user-level `requires:`/`ensures:` are gated. System-level range/invariant checks always run.

Closes issue #7640.

---

**Status:** Shipped in this decision (D-progress-1017). The `[contracts] enabled` field is implemented in the self-hosted compiler on both MSIL and JVM targets.

**Verification:** 
- The language reference (§3.7) and book document the table and gating behavior.
- The self-hosted elaborator (`contract_elaborator/elaborator.l`) gates only user-level `requires:` and `ensures:` clauses.
- System-level structural checks (parameter/return range checks, protected-type invariants) are never gated and always run.
- All build paths (single-file and project-based, MSIL/JVM/native) respect the manifest `[contracts] enabled` setting for the consuming project's own package(s). The standard library's and dependencies' own declared contracts are unaffected on every target (#7748).
