# G1 review follow-ups: bench exit codes, CI coverage, ABI notes

Suggestions from the reviews of #8127, #8138 and #8139, taken up together.

- **`lyric bench` exit codes.** A missing or malformed flag value (`--runs`,
  `--warmup`, `--filter`, `--manifest`, `--triple`, `--opt`, `--target`)
  exited 1 while an out-of-range one exited 64; docs/01 has always said a
  usage error is 64. Every flag error is now 64. A `wasm32` triple is a
  usage error too; a manifest that cannot be read stays 1
  (`resolveNativeBenchConfig` returns a `BenchConfigError` carrying the
  code). The usage text says `--triple`/`--opt` apply to `--target native`
  and that a `wasm32` triple is refused.
- **Inline range e2e on dotnet and the JVM.** `scripts/ci/range-refinement-e2e.sh`
  ran only on native; it now also runs for dotnet and the JVM in the compiler
  self-test batch, beside `fixed-array-e2e.sh`.
- **Float rendering.** `float32_self_test.l` adds a Float subnormal that
  rounds up across a digit on the JVM (`1E-44`, Java `9.8E-45`) and a small
  normal Double that keeps two digits (`2.5E-300`), and its comment names
  which cases exercise each path of the JVM normaliser.
- **C ABI notes.** `cAbiPlanOf` says why only x86-64 tracks an argument
  register budget, and docs/01, docs/67, book chapter 13 and appendix B say
  that a by-value record in an `extern func` on a Windows triple is still
  `N0010`.
