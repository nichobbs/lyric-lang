# Checker strictness, docs/70 phase 1 (D280, #8611)

The first phase of the docs/70 restructure (D267) ships on the existing
checker:

- T0211 for a dependency whose signatures or impls do not resolve, replacing
  the discarded `importedDiag`/`implDiag` lists; T0097 no longer misfires on
  a package's own private types while its impls are registered.
- Union, `Option` and `Result` method calls bind only functions the file can
  call bare (T0113).
- `Pkg.Type` resolves only in `Pkg` or what it re-exports (T0014); an
  uppercase call receiver that names nothing is T0020 in the checker.
- T0212 (#7214): a `pub`/`internal` signature or record field may not name a
  less-visible type of its own package. The 13 files that exposed such types
  were fixed by marking the exposed types `pub`.
- The LSP checks each imported workspace package under its own name and
  imports.
- Compile-fail corpus `lyric-compiler/lyric/testdata/reject/`, run on dotnet
  and the JVM by `scripts/ci/reject-corpus.sh` in CI.

The I0001 gate moves to phase 3 (D280): 11,561 silent `TyError` results on
the compiler's own sources, mostly benign callee positions, make it a TIR
builder property rather than a gate on the current checker.

Docs: language reference §3.1 (T0212) and §9.2; book chapter 6 and appendix
B; docs/70 §5.3 and §13.
