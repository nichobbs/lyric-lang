# D552 - Protected-type entries are TIR declarations with a barrier (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319, D323 and D389; makes concrete what docs/70 section 9.2 already says
("protected types with entries and barriers").

## Context

The TIR census put protected types behind two kinds: `a method, constructor or member call`
(58; the first site was `Total()`) and `a method call with no declared receiver` (39; entry
calls such as `t.add(n)`). `Lyric.Tir` had nothing to build them into: an entry is declared
without a receiver, runs under the type's lock and may carry a `when:` barrier.

## Decision

- A protected type's construction is an `XConstruct` of the type, its fields in declaration
  order with defaults filled in. The checker records the construction's signature
  (`ctorSigByNode`) for a non-generic protected type as it does for a record.
- `TSymKind` gains `TSkEntry`, for an entry or `func` of a protected type. Its `TSig` has the
  protected value as the first parameter, passed `in` (the value is a reference; the lock is the
  backend's business).
- An entry call `t.add(n)` is a direct `XCall` of the entry symbol, receiver first, built by the
  method-call path: the checker's receiver-less signature is recognised by its receiver being a
  protected type.
- `TFnDecl` gains `barrier: Option[TExpr]` (default `None`): the `when:` guard, a `Bool` over the
  receiver's fields and the entry's parameters. `Lyric.Tir.Verify` visits it and requires `Bool`
  (rule `condition-type`).
- The TIR carries no locks. Backends lower locking and the barrier wait from the declaration, as
  they do today from the AST.

Building entry declarations (bodies and barriers) arrives with the slice that builds methods and
impl members, which the census does not walk yet.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 967 -> 969 of 1165, I0003 0,
`a method call with no declared receiver` 39 -> 30, `a method, constructor or member call` 58 -> 56.
The 30 that remain are receivers that are not protected types (an `HttpClient` method, a method of
an imported generic receiver such as `List[MapEntry[..]].add`), the next slices. The first protected
sites now build as far as `scope` and `defer` (`async_mt_tsan_main.l`).
