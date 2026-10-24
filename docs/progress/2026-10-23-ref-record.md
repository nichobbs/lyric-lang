# 2026-10-23 - `ref record` marker and W0031 (D222, #7955)

- **Syntax.** `ref record Name { ... }` (contextual `ref`, after visibility) in the parser,
  `RecordDecl.isRef`, the formatter, `lyric doc`, `docs/grammar.ebnf` and the reference
  (section 3.4). Every AST pass that rebuilds a `RecordDecl` carries the flag.
- **Warning W0031.** A record with a `var` field that is not `ref` is warned, with the fix
  in the message. The protected-type lowering marks its synthesised record.
- **Migration.** Records with `var` fields are marked across the ecosystem libraries,
  examples, tests and compiler self-tests. The compiler's own sources and the
  seed-compiled stdlib packages keep the plain spelling until the stage-0 seed learns
  `ref record` (the seed's parser rejects it); that refresh also makes W0031 an error.
- **Tests.** `parser_self_test.l`, `fmt_self_test.l`, `typechecker_self_test.l` and
  `record_semantics_self_test.l` cover parsing, formatting, the warning and the
  unchanged runtime semantics.
