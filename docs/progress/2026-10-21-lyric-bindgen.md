# `lyric bindgen` (docs/67 G3 S3, #7942, D190)

- `Lyric.Bindgen` (`lyric-compiler/lyric/bindgen/bindgen.l`): clang AST JSON to a kernel
  binding file; allow-list with wildcard patterns and `userdata` directives; skips and
  reports what the native backend cannot pass; named-but-unbindable symbols are errors.
- CLI: `lyric bindgen` (`cli/cli_bindgen.l`) with `-o`, `--library`, `-I`, `--clang-arg`,
  `--long-bits`, `--check`.
- Tests: `bindgen_self_test.l` runs clang over a header, checks the generated text and
  skips, then compiles the bindings with a C implementation and runs them under
  AddressSanitizer.
- Docs: D190, language reference §13.11a, book (getting started, chapter 13, appendix B),
  docs/67 §5.3.
- Native codegen: a callback type's parameters and result resolve against the package (a
  `NativePtr[Record]` in a callback signature names a declared record).
- Checker: T0181, a function-typed `extern func` parameter with no userdata slot, replaces
  a codegen panic with a diagnostic.
