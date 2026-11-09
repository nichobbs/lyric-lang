# D555 - The `--release` profile at v1.0: what it drives, and what it does not (#6263, #8946)

**Status:** accepted

Closes #6263 (v1.0 exit criterion 5, `docs/12-todo-plan.md`).

## Context

#6263 asked for the build profile to reach the backends. By the time of this
entry every behaviour it listed has an implementation: integer overflow (D163),
contract elision (D297 for free functions, D307 for record, `impl` and
protected-type methods) and the native clang `-O` level (D-progress-913). What
remained was the optimisation row, and documentation that still described
`--release` as "optimized, debug info stripped" (the book, appendix B,
docs/01 section 13) or as not removing contracts (docs/01 section 6).

## Decision

1. `--release` is a real profile. Its v1.0 meaning is exactly the table in
   docs/01 section 13: overflow wraps, `ensures:` and internal `requires:` are
   not checked, and the native `-O` level defaults to 2. `--debug` is the
   opposite on each row.
2. On `--target dotnet` and `--target jvm` the profile does not change the
   generated IL or bytecode. Lyric has no optimisation pass on those targets,
   and the runtime's JIT optimises both outputs alike. This is documented as
   such and tracked as #8946 (2026-11-09); it is not a silent no-op.
3. No target emits debug information, so `--debug` does not "retain" it and
   `--release` does not "strip" it. That half of the profile stays with docs/63
   bands B1-B7.
4. The docs/05 exit criterion "runtime performance competitive with C#" is
   restated as a claim about the JIT-compiled `--target dotnet` output checked
   against `benchmarks/`, not as something `--release` delivers.

## Consequences

No compiler change. The wording of docs/01, docs/05, docs/12, docs/63, docs/67,
book chapter 1 and appendix B now matches the behaviour above. The
debug-versus-release behaviour differences are covered by the existing
`scripts/ci/release-contracts-e2e.sh` (contracts, three targets) and the D163
overflow self-tests; this entry adds no test of its own.
