# 2026-11-13 - Constructor patterns name every field of their case: T0229 (D480)

docs/70 phase 3a, #8613, the owner's decision on short constructor patterns. The checker rejects a constructor pattern with more or fewer sub-patterns than its case has fields (T0229); the compiler sources and one self-test that used short patterns now name every field with `_`; TIR no longer pads (`padCasePats` removed). docs/01 section 4.2 and the book's pattern chapter state the rule; `typechecker_self_test.l` and the reject corpus (`ctor_pattern_short`, `ctor_pattern_long`) pin it.
