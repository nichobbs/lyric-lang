# D-progress-956 — Contract violations name the kind, owner and clause (#7225)

**Status:** shipped

## Problem

The contract elaborator lowered every clause to a bare `assert(cond)`, so
every violation on every target raised the same text, `assertion failed`.
Nothing said which function, which clause or which kind of contract had
failed. The `PreconditionViolated` / `PostconditionViolated` /
`InvariantViolated` tags in the language reference and the book did not
exist at runtime. The native backend also ignored an `assert`'s message
argument.

## Decision

- Each synthesized assert carries a message:
  `<Kind>: <owner> <keyword> <clause>`. Examples:
  `PreconditionViolated: Division.divide requires d != 0` and
  `PostconditionViolated: Pkg.Type.method ensures result >= 0`.
- Protected-type invariants checked at entry exit use `InvariantViolated`
  with the owner `Pkg.Type.entry`. Loop invariants use
  `LoopInvariantViolated: invariant <clause>`; they are elaborated without
  an owner in scope.
- The clause text is rendered from the AST with `Lyric.Fmt.exprInline`, so
  it is the canonical formatting of what the author wrote. Spans carry no
  file name, and a line number in a merged multi-file package would be
  misleading, so the message names the package-qualified function instead.
  JVM stack frames still carry real source lines.
- The owner is the package-qualified function name. Record-body methods
  report `Pkg.Type.method`, and `impl` methods report
  `Pkg.<target type>.method`, including clauses inherited from the
  interface (D-progress-955).
- The failure stays an ordinary panic (a `Bug`), so `catch Bug as b`
  observes `b.message` unchanged. The native backend now uses a literal
  `assert` message argument instead of always printing `assertion failed`.
- The language reference's "configurable in release" for `@runtime_checked`
  never had an implementation. It is replaced by the shipped behaviour:
  contracts are checked in every build profile.

## Verification

`method_contracts_self_test.l` asserts the exact message for a record-method
precondition and for an inherited postcondition on `--target dotnet` and
`--target jvm`. The native backend was checked by hand
(`lyric panic at Nat:6: PreconditionViolated: Nat.divide requires d != 0`).
The book's violation-output examples (chapters 8 and 17) now show the real
output. They had shown counterexample values that the runtime never
captured.
