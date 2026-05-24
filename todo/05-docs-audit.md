# Tier 5 — Documentation and Audit

## Issues
- **#335** — `docs/17-axiom-audit.md` stale: lists 16 entries but code has 38+ actual axioms; axiom strings contradict actual code
- **#367** — 24 ecosystem libraries shipped without honest experimental/preview framing
- **#425** — Compiler-core LOW items: fix in self-hosted lexer/parser/type-checker (not F#)

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else.

Your task is to fix all three documentation and audit issues listed above. Work on a new branch named `fix/tier5-docs-audit`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

All compiler fixes go in self-hosted Lyric files (`.l`). The F# bootstrap lexer/parser/type-checker are frozen — do not touch them except for item 7 in #425 (the bootstrap entry-point musl fix, which is acceptable). Documentation changes go in `docs/`. The book (`book/`) must be updated in sync with language reference changes.

---

### #335 — `docs/17-axiom-audit.md` stale

The axiom audit document at `docs/17-axiom-audit.md` is severely out of date:

- **Count table** lists 16 stable + 0 provisional axioms. Actual count from scanning `lyric-stdlib/std/_kernel/*.l` and `lyric-stdlib/std/_kernel_jvm/*.l` is 38+. Missing entries include `Std.PathHost`, `Std.ConsoleHost`, `Std.ProcessCaptureHost`, `Std.JvmExceptionHost`, `Std.VerifierEnvHost`, and all `lyric.stdlib.jvm.*` axioms.
- **Quoted axiom strings** in the document contradict actual code:
  - §doc quotes `@axiom("System.Int32/Int64/Double/Boolean.TryParse ...")` but `parse_host.l` says `@axiom("System.Double/Boolean.TryParse...")` (Int32/Int64 removed when pure-Lyric int parsing landed)
  - §doc quotes `@axiom("System.Convert and System.Text.Encoding ...")` but `encoding_host.l` says `@axiom("placeholder — no host calls remain in this boundary file")`

**Fix:**

1. Write `scripts/audit-axioms.sh`: a script that scans every `_kernel/*.l` and `_kernel_jvm/*.l` file, extracts `@axiom("...")` strings and the function names they annotate, and outputs a structured table (package, function, axiom string, platform). The script should fail with a diff if its output does not match a recorded baseline in `docs/17-axiom-audit.md`.

2. Run the script and regenerate `docs/17-axiom-audit.md` §18 "Axiom count by kernel package" table to reflect the true counts.

3. Update every quoted axiom string in the document to match the actual `@axiom(...)` text in the current kernel files — re-scan each section and fix all discrepancies.

4. Add `scripts/audit-axioms.sh` to `.github/workflows/ci.yml` as a lint step that fails the build if the audit document is out of sync with the kernel files. This prevents future staleness.

---

### #367 — 24 ecosystem libraries premature framing

The repository ships 24 ecosystem libraries (`lyric-mq`, `lyric-session`, `lyric-ws`, `lyric-web`, `lyric-mail`, `lyric-jobs`, `lyric-storage`, `lyric-auth`, `lyric-resilience`, `lyric-validation`, `lyric-ws`, `lyric-cache`, `lyric-db`, `lyric-health`, `lyric-logging`, `lyric-otel`, `lyric-proto`, `lyric-grpc`, `lyric-feature-flags`, `lyric-i18n`, `lyric-testing`, `lyric-aws-secrets`, `lyric-aws-xray`, `lyric-lambda`) without honest experimental/preview status marking. Several have no tests; some have known stubs or silent no-ops.

**Fix — choose the honest framing per library:**

For each library, assess its current state:
- **Operational with tests** (e.g. `lyric-auth`, `lyric-mq` with real broker, `lyric-aws-secrets`): leave as-is; add `@stable(since="0.x")` or `@experimental` to the top-level module doc-comment as appropriate.
- **Operational but untested** (e.g. `lyric-session`, `lyric-storage` post Tier 1 fix): mark `@experimental` in the module doc-comment; add a `// WARNING: experimental — no stability guarantee` banner at the top of the public `.l` file.
- **Known stubs or silent no-ops** (e.g. `lyric-health` dispatcher not implemented, `lyric-ws` rate-limiter has one-time burst budget): mark `@experimental` AND add `requires:` contracts or `panic("not yet implemented")` where the silent no-op would produce incorrect behaviour.

Update `docs/05-implementation-plan.md` to reflect which libraries are genuinely production-ready vs experimental. Update `book/chapters/appendix-b-quick-reference.md` to remove "shipped" language for experimental libraries.

Do not remove any library from the repository. The goal is honest labelling, not deletion.

---

### #425 — Compiler-core LOW items (self-hosted only)

Fix the following items in the **self-hosted** Lyric compiler. Do NOT touch `bootstrap/src/Lyric.Lexer/`, `bootstrap/src/Lyric.Parser/`, or `bootstrap/src/Lyric.TypeChecker/` for any of these except item 7.

**Item 1 — `_UpperCase` ident L0040 keeps emitting `TIdent`** (`lyric-compiler/lyric/lexer.l`):
L0040 fires but the lexer still emits `TIdent "_Foo"`. This can clash with compiler-generated names (`_Async`, `_StateMachine`). After emitting L0040, replace the token with a `__error_<n>` placeholder that the parser treats as an error recovery token, preventing the downstream name from propagating.

**Item 2 — `lexBlockComment` doesn't detect `// /*`** (`lyric-compiler/lyric/lexer.l`):
Block and line comments don't nest idiomatically. A `// /*` sequence should not open a block comment. Verify the self-hosted lexer handles this case correctly; if not, add the guard.

**Item 3 — `peek` past EOF returns span 0:0** (`lyric-compiler/lyric/parser/parser_core.l`):
If a recovery path calls `peek` after the last token, the resulting synthetic token has span 0:0 rather than the source end. Fix `peek` to return a synthetic EOF token with `span = (source.length, source.length)`.

**Item 4 — Type-as-expression range discard** (`lyric-compiler/lyric/parser/parser_exprs.l`):
`(Nat range 1..=100).tryFrom(x)` discards the refinement — only the head `Nat` is kept. Fix the parser to preserve the full range-subtype in a type-as-expression context. Add a parser self-test covering this case.

**Item 5 — `ConstFold` cannot represent `Long.MinValue`** (`lyric-compiler/lyric/type_checker/typechecker_constfold.l`):
The literal `9223372036854775808u64` is rejected before `PreNeg` applies. Fix by parsing `PreNeg + literal` as a single unit in the constant folder, allowing `Long.MinValue` to be expressed as `-9223372036854775808`.

**Item 6 — `Type.render TyUser` produces `<#7>`** (type-checker render):
When rendering a `TyUser(TypeId 7, [])` for an error message, the output is `<#7>` because the declared name is not tracked. Fix the renderer in `lyric-compiler/lyric/type_checker/typechecker_types.l` to carry declared names in the type environment and use them in `render`.

**Item 7 — `Program.fs` uses `MainModule` which can be null on musl Linux** (`bootstrap/src/Lyric.Cli.Aot/` or `bootstrap/src/Lyric.Cli/Program.fs`):
Replace `Assembly.GetEntryAssembly().Location` or `MainModule.FileName` with `Environment.ProcessPath` (.NET 6+), which returns the correct value on musl Linux. This IS an acceptable F# change (bootstrap entry-point infrastructure, not domain logic).

**Item 8 (NIT) — `codepointToLong` O(n) loop** (`lyric-compiler/lyric/verifier/vcgen.l:163-179`):
Replace the manual loop with a direct cast. This is a NIT but worth fixing for clarity.

**Item 9 (NIT) — `prevWasStmtEnd` state split** (`lyric-compiler/lyric/lexer.l`):
Factor a `Lexer.afterEmit(state, tok)` helper to consolidate the scattered `prevWasStmtEnd` updates. NIT, but improves maintainability.

For each item, add or extend a self-test that would have caught the bug. Self-tests live in `lyric-compiler/lyric/*_self_test.l`.

---

## Acceptance Criteria

- [ ] `scripts/audit-axioms.sh` exists and produces a structured axiom table from kernel files
- [ ] `docs/17-axiom-audit.md` count table reflects true axiom counts (38+ entries)
- [ ] Every quoted axiom string in `docs/17-axiom-audit.md` matches the actual `@axiom(...)` text in current kernel files
- [ ] `audit-axioms.sh` runs as a CI lint step and fails if the doc is out of sync
- [ ] Every ecosystem library has an `@experimental` or `@stable` annotation in its module doc-comment
- [ ] No library has a silent no-op that accepts a call and returns `Ok` while doing nothing
- [ ] `docs/05-implementation-plan.md` accurately reflects which libraries are production-ready vs experimental
- [ ] `book/chapters/appendix-b-quick-reference.md` does not claim "shipped" for experimental libraries
- [ ] L0040 `_UpperCase` identifier emits a `__error_<n>` placeholder, not `TIdent`; self-test added
- [ ] `peek` past EOF returns a synthetic EOF span at source end, not 0:0; self-test added
- [ ] Type-as-expression preserves range-subtype refinement; self-test added
- [ ] `Long.MinValue` constant folds correctly via `PreNeg + literal`; self-test added
- [ ] `Type.render TyUser` emits declared name, not `<#7>`; self-test added
- [ ] `Environment.ProcessPath` used in bootstrap entry point instead of `MainModule` (musl fix)
- [ ] `codepointToLong` replaced with direct cast
- [ ] `prevWasStmtEnd` factored into `afterEmit` helper
- [ ] All self-tests in `lyric-compiler/lyric/lexer_self_test.l`, `parser_self_test.l`, `typechecker_self_test.l` pass
- [ ] `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes
- [ ] No F# changes to `Lyric.Lexer`, `Lyric.Parser`, or `Lyric.TypeChecker` projects
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
