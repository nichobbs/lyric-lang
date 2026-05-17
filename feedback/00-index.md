# Lyric Code Review — Findings Index

Comprehensive review of the Lyric language project (commit `3e5484c`,
branch `claude/code-review-feedback-tWv2n`). Seven specialised review
agents ran in parallel against the compiler, verifier, stdlib,
ecosystem libraries, security-sensitive surfaces, test suite/CI, and
overall architecture. Each numbered file below is the full report from
one agent; this index summarises the headline issues and points to the
most urgent fixes.

## Files

| # | Area | LOC | CRIT | HIGH | MED | LOW/NIT |
|---|------|----:|-----:|-----:|----:|--------:|
| 01 | Verifier and proof system | 282 | 2 | ~9 | several | — |
| 02 | Compiler core (lexer/parser/typechecker/emitter/bridges) | 556 | 2 | 14 | ~17 | ~5 |
| 03 | Stdlib (Lyric `std/` + kernel boundary) | 621 | 0 | 13 | 11 | 5 |
| 04 | Security review (ecosystem libs + foundational stdlib) | 1006 | 2 | 7 | 8 | 3 |
| 05 | Ecosystem libraries (lyric-*) | 813 | 2 | 6 | 10 | 7 |
| 06 | Tests and CI | 366 | 0 | 4 | 9 | 6 |
| 07 | Architecture and strategy | 800 | 2 | 5 | several | — |

Across reviews: **~110 distinct substantive findings**, with broad
agreement on a small number of headline issues (the verifier async/yield
gap surfaces independently in #01, #02, and #07; the zero-test ecosystem
surfaces in #03, #05, #06, and #07).

## Headline issues (cross-cutting consensus)

These were flagged by multiple agents and should be triaged first.

1. **CRITICAL — Verifier silently passes async/yield code.**
   `VCGen.fs:842-850` opaques any unmodelled expression; `IsAsync` is
   hardcoded `false` (`VCGen.fs:1466`); `bodyContainsYield` is checked
   only at emit-time. The user's flagged "proof checker not supporting
   async/yield" turns out to be worse than missing — it is *silent*:
   `@proof_required` async functions verify vacuously. Fast fix: emit
   a new `V0008` diagnostic that rejects `@proof_required` (or any
   contract) on `async`/`yield`-bearing bodies. (See #01 §Missing
   features and #07 F-1.)

2. **CRITICAL — Two unsoundness bugs in the VC IR.** `Term.subst` is
   not capture-avoiding (`Vcir.fs:167-188`, `vcir.l:391-454`), and
   `wpBody` returns `Wp = trueT` for unsupported statements (vacuous
   discharge). Both surface in self-hosted port too. (See #01.)

3. **CRITICAL — Surrogate-range escape crash in the F# lexer.**
   `Char.ConvertFromUtf32` throws on `\u{D800}`–`\u{DFFF}`; the lexer
   doesn't guard. 3-line fix. Reproducibility implication: self-hosted
   lexer *rejects* all non-BMP escapes, so the three-stage bootstrap
   in `scripts/bootstrap.sh` is broken for any source touching them.
   (See #02 CRIT-1, CRIT-2.)

4. **CRITICAL — JWT verification has no algorithm pinning.**
   `Auth.verifyJwt` accepts a single `secret` with no `allowedAlgorithms`
   parameter (`lyric-auth/src/auth.l:44-53`). Classic `alg=none` /
   HS256-as-RS256 attack surface across every endpoint that uses
   lyric-auth (HTTP, WebSocket, gRPC). (See #04 FINDING-01.)

5. **CRITICAL — Session fixation via `set()` auto-creation.** Both
   `NativeSessionStore.set` and `InProcessSessionStore.set` create a
   new session for any attacker-supplied ID (`lyric-session/src/
   session.l:199-219, :342-365`). (See #04 FINDING-02.)

6. **CRITICAL — `lyric-mq` package cannot resolve.** `lyric.toml`
   omits the `dotnet`/`jvm` features that `mq.l` `@cfg`s on; the
   package is broken as published. (See #05 F-1.)

7. **CRITICAL — Zero tests across 24 ecosystem libraries.** ~16k LOC
   of shipped library code with no `*_tests.l` file in any package.
   Combined with the next item, every `pub aspect` template in the
   ecosystem is silently inert with no diagnostic. (See #05 F-3, #06,
   #07 F-2.)

8. **HIGH — `@inline_template` and `pub aspect` templates are inert.**
   Neither annotation is recognised by the F# or self-hosted compiler;
   60+ public surface items across 11 ecosystem libraries depend on
   them (`lyric-grpc/RequiresGrpcAuth`, `lyric-mq/Idempotent`,
   `lyric-cache/Cached`, etc.). (See #07 F-3.)

## Severity-organised quick read

If you only have time for one pass, read in this order:

1. **#01 Verifier** — the two soundness bugs and the async/yield gap.
2. **#04 Security** — JWT and session fixation are deployment-blocking.
3. **#07 Architecture** — for the v1.0 critical path decision tree
   (what to cut / what to gate behind `@experimental`).
4. **#02 Compiler core** — surrogate crash, pattern-exhaustiveness gap,
   self-hosted divergences that affect bootstrap reproducibility.
5. **#05 Ecosystem libraries** — for the `lyric-mq` packaging bug and
   the per-feature NuGet gating that pulls 150 MB of unused deps.
6. **#03 Stdlib** — YAML/JSON correctness, cross-platform parity gaps
   (`Std.Json`/`Console`/`Path`/`ProcessCapture` don't link on JVM).
7. **#06 Tests/CI** — coverage matrix and CI gaps (no platform matrix,
   no lint/fmt gate, no bootstrap in CI).

## What's working well

Each report calls out positive observations; the headline ones:

- **Self-hosting boundary discipline holds.** Sampled `SelfHosted*.fs`
  bridges are genuinely thin protocol shims, not logic accretion (#07
  F1). The "F# surface is frozen" rule is being honoured.
- **MSIL pipeline is the default** (`--target dotnet`); the legacy F#
  emitter remains as a tested fallback (#07).
- **Contract elaborator preserves source spans** through every rewrite
  (#02).
- **Aspect-template documentation is uniformly strong** across the
  ecosystem libraries — the implementation just hasn't landed (#05).
- **`lyric-proto` defensive decoder** and **`lyric-auth` constant-time
  helper** are exemplary (#05, #04).
- **Stdlib extern-boundary invariant** (`@externTarget` / `extern type`
  only inside `_kernel*/`) is enforced (#03).
- **Stdlib parser overflow guard** in `parseDigits` is textbook-correct
  (#02).

## Suggested triage

**Block v1.0 on:**
- Verifier soundness (#01 CRIT-1, CRIT-2, async/yield)
- JWT and session fixation (#04 CRIT-1, CRIT-2)
- Surrogate crash (#02 CRIT-1)
- `lyric-mq` packaging (#05 F-1)
- Either ship tests for the 24 ecosystem libraries, or reclassify them
  as `@experimental` / "early preview" and drop from
  `appendix-b-quick-reference.md` (#05 F-3, #07 F-13)

**Land in next minor release:**
- Pattern exhaustiveness (#02 HIGH)
- Cross-platform parity for `Std.Json`/`Console`/`Path`/`ProcessCapture`
  (#03 HIGH)
- `LYRIC_STRICT_SDK_VERSION` enforcement (#07 F-4)
- Aspect-template instantiation (#07 F-3 / docs/36 §G-06)

**Backlog:**
- Bootstrap reproducibility verification in CI (#06)
- Stdlib test coverage gaps (#03, #06)
- API consistency and error-model alignment across `lyric-*` (#05 F-10)
