# 2026-09-28 — Documentation for `[contracts]` manifest table

#7640.

The `[contracts]` manifest table controls compile-time contract behavior per project:

```toml
[contracts]
enabled = true   # default: true
```

When `enabled = false`, the compiler parses and type-checks all contract clauses but does not synthesize runtime checks. This is useful for production builds where contract overhead is unacceptable after offline verification. Proof obligations for `lyric prove` are unaffected.

**Documentation updates:**

- **Language reference** (§3.7): Added new section "Contract compilation — `[contracts]`" describing the table, its fields, defaults, and semantics. Cross-references the verification chapters (§6.4 and Chapter 17).
- **Book chapters**: Added "Contract checking — `[contracts]`" subsection in chapter 01 (getting-started), positioned after "Build profile and output shape" to align with manifest configuration topics. Explains the table, examples, and use case (production optimization after formal verification).

This documents D132's `[contracts] enabled` field implementation and closes issue #7640.
