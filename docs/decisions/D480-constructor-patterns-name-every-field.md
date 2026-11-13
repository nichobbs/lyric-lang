# D480 - A constructor pattern names every field of its case (T0229)

**Status:** shipped; supersedes the "padded with wildcards" part of D578 and D585 (docs/70 phase 3a, #8613).

## Context

The checker accepted a constructor pattern with fewer sub-patterns than the case has fields, every backend bound the leading fields and ignored the rest, and D578 made TIR pad the missing trailing ones with wildcards. The owner decided the checker rejects it: a short pattern hides a field that was added or reordered later, and TIR should not carry a rule the language does not state.

## Decision

- **T0229.** A constructor pattern whose sub-pattern count differs from the case's field count is an error, whichever way it differs, naming the case, its field count and the pattern's count; `_` stands for a field the pattern does not use. A nullary case is written without parentheses (or with none), and an enum case has no fields.
- The rule applies to the patterns of `match` arms, local `val` destructuring and `for` bindings, at every nesting depth; an enum case has no fields, so `Red(x)` is an error as well.
- The builder no longer pads (`padCasePats` is deleted); `TpCtor` carries exactly the sub-patterns written, and the verifier's pattern-arity rule is the guard.
- Census before the rule: the compiler's own sources (11 patterns across `fmt`, the type checker, `llvm_codegen.l` and the JVM codegen), one self-test, and every manifest and test program in the repository (898 `lyric check` runs, the compiler-importing ones with the compiler loaded) were checked; every pattern found was completed with `_` in the same change, and the rule was not weakened.

## Tests

`typechecker_self_test.l` pins the shapes (fewer, more, full arity with a wildcard, a `val`, a `for`, an enum case with parentheses); `testdata/reject/ctor_pattern_short`, `ctor_pattern_long`, `ctor_pattern_val` and `ctor_pattern_for` are the reject corpus cases on both targets.
