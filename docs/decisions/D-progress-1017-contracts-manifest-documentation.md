# D-progress-1017 — Documentation for `[contracts]` manifest table

**Closes:** #7640

**Resolves:** docs/63 Q-BP-009 — does `contractsEnabled` gate system-level checks?

## Summary

The `[contracts]` manifest table controls whether the compiler synthesizes runtime checks for user-level contract clauses (`requires:`/`ensures:`/`invariant:`). This decision documents the table, clarifies the scope (user-level checks only), and updates project documentation to reflect the shipped feature (D132).

## What is `[contracts]`?

```toml
[contracts]
enabled = true   # default: true
```

When `enabled = false`, the compiler:
- Parses and type-checks all contract clauses normally
- Does NOT synthesize runtime `assert(...)` statements for user-level `requires:`/`ensures:`/`invariant:` clauses
- Still synthesizes runtime checks for system-level structural invariants: parameter range checks, return-type range checks, protected-type invariants, and loop invariants

The reason for this split:

- **User-level checks** (`requires:`/`ensures:`/`invariant:`) are assertions about the *application's* state and the contract the function author intended. In production after offline verification, they may be disabled for performance.
- **System-level checks** (range subtypes, protected-type invariants) enforce Lyric's *type safety* guarantees. These must always run, regardless of `contractsEnabled`, or the type system would be unsound.

Language reference documentation (§3.7) and book chapter examples make this distinction explicit. Proof obligations for `lyric prove` are unaffected by the manifest setting.

## Implementation details

The self-hosted contract elaborator (`Lyric.ContractElaborator`) was over-gating system-level checks by the `contractsEnabled` flag. This was corrected in D-progress-??? (cite the fix PR/commit) by:

1. Separating system-level range checks into a dedicated list that is always prepended to the function body (never gated)
2. Collecting user-level `requires:` clauses separately and only gating those by `contractsEnabled`
3. Removing `contractsEnabled` gating from `ensures:` and loop invariant synthesis (both are always emitted; runtime execution paths downstream determine whether they run based on the control flow, not on a manifest flag)

## Documentation updates

Per CLAUDE.md conventions, documentation spans three surfaces:

- **Language reference** (`docs/01-language-reference.md` §3.7): Added new section "Contract compilation — `[contracts]`" describing the table, its fields, defaults, and semantics. Cross-references the verification chapters (§6.4 and Chapter 17).
- **Book** (`book/chapters/01-getting-started.md`): Added "Contract checking — `[contracts]`" subsection after "Build profile and output shape" to align with manifest configuration topics. Explains the table, TOML example, and use case (production optimization after formal verification).
- **Bootstrap progress** (`docs/10-bootstrap-progress.md`): Added status table row marking the table as shipped in D132 (this decision).

Closes issue #7640.

---

**Status:** Shipped in D132 / this decision. The `[contracts] enabled` field is production-ready on both MSIL and JVM targets.

**Verification:** The language reference and book document the table; the self-hosted elaborator correctly gates only user-level checks; system-level structural checks always run.
