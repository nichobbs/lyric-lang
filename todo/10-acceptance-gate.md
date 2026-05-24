# Tier 10 — Band 7 Acceptance Gate

## Issues
- **#859** — Band 7: delete F# emitter (`Emitter.fs`), `--target dotnet-legacy`, and all bootstrap shims; self-hosted compiler is the sole production path

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else, then read `docs/23-fsharp-shim-elimination.md` (the shim-elimination plan) and `docs/41-self-hosted-compiler-gap-analysis.md` (band gap analysis). Also read the Band 7 entry in `docs/05-implementation-plan.md`.

Your task is to execute the Band 7 acceptance gate. This is the final and irreversible step toward a fully self-hosted Lyric compiler: after this PR merges, the F# bootstrap emitter is gone and the self-hosted Lyric compiler is the sole production path for all targets. Work on a new branch named `feat/tier10-acceptance-gate`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. This PR must only be marked ready for review once **all previous tiers (1–9) are complete and merged**.

Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

**This is a deletion PR.** The primary work is removing code, not adding it. Every line of F# deleted must be replaced by verified Lyric behaviour — not silently dropped.

---

### #859 — Band 7: Delete F# emitter and bootstrap shims

**Pre-condition verification — run this BEFORE touching any file:**

Tier 7 deletions are irreversible without a `git revert`.  The session must
prove every pre-condition mechanically before any deletion runs.  Copy the
following block verbatim into the first step of the session and inspect every
output; if any check fails, post a comment on this PR listing the failing
condition, then stop.  Do not proceed to the deletion sequence.

```sh
# 1. All tier branches merged.  The list must contain ten entries.
gh pr list --repo nichobbs/lyric-lang --state merged \
  --search 'in:title fix/tier1 fix/tier2 fix/tier3 fix/tier4 fix/tier5 fix/tier6 feat/tier7 feat/tier8 feat/tier9' \
  --json number,title,mergedAt

# 2. Self-hosted pipeline runs the full emitter test suite with zero skips.
dotnet run --project bootstrap/tests/Lyric.Emitter.Tests 2>&1 \
  | tee /tmp/emitter-tests.log
grep -E "skipped|ignored" /tmp/emitter-tests.log  # must be empty

# 3. CLI suite also at zero skips.
dotnet run --project bootstrap/tests/Lyric.Cli.Tests 2>&1 \
  | tee /tmp/cli-tests.log
grep -E "skipped|ignored" /tmp/cli-tests.log     # must be empty

# 4. Stdlib manifest test runner passes on both targets.
lyric test --manifest lyric-stdlib/lyric.toml --target dotnet
lyric test --manifest lyric-stdlib/lyric.toml --target jvm

# 5. Stage-3 reproducibility: self-hosted² == self-hosted¹.
./scripts/bootstrap.sh --stage 3
```

If any step exits non-zero, or any tier branch is missing from step 1, **stop**.
Comment on this PR listing the failing condition, then end the session.  Fix
the failing condition in the appropriate tier's PR before re-opening this one.

**Itemised pre-conditions (each must be machine-verified by the snippet above):**

1. All tiers 1–9 are merged to `main`.
2. `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes with zero skipped tests via the self-hosted pipeline (no fallback to `Emitter.fs`).
3. `dotnet run --project bootstrap/tests/Lyric.Cli.Tests` passes with zero skipped tests.
4. `lyric test --manifest lyric-stdlib/lyric.toml` passes on both `--target dotnet` and `--target jvm`.
5. `scripts/bootstrap.sh` stage-3 reproducibility check passes (self-hosted² binary matches self-hosted¹ binary).

---

**Deletion sequence (do in this order; verify CI after each step):**

**Step 1 — Remove `--target dotnet-legacy` flag**

In `lyric-compiler/lyric/cli.l` (and any F# trampolines that reference it), remove the `--target dotnet-legacy` flag and all code paths that route through the F# bootstrap emitter. Any call site that branched on `target == "dotnet-legacy"` must now use the self-hosted MSIL pipeline unconditionally.

Update `docs/01-language-reference.md` CLI reference to remove `--target dotnet-legacy`.
Update `book/chapters/appendix-b-quick-reference.md` accordingly.

Verify: `lyric build --target dotnet-legacy` must now print `"unknown target 'dotnet-legacy'"` and exit non-zero.

**Step 2 — Delete `Lyric.Emitter` F# project**

Delete `bootstrap/src/Lyric.Emitter/` entirely. This includes:
- `Emitter.fs` — the F# MSIL emitter (the primary deletion target)
- `Weaver.fs` — the F# aspect weaver (replaced by `lyric-compiler/lyric/weaver/weaver.l`)
- `TestSynth.fs` — the F# test synth (replaced by `lyric-compiler/lyric/test_synth/test_synth.l`)
- `ProcessCapture.fs` — the F# process capture host (replaced by the kernel extern boundary)
- `Formatter.fs` — the F# formatter shim (replaced by `lyric-compiler/lyric/fmt/`)
- All other `.fs` files in the project

Remove the `Lyric.Emitter` project reference from `Bootstrap.sln` and from every `.fsproj` that references it.

After this step, `dotnet build Bootstrap.sln` must succeed (no dangling references).

**Step 3 — Delete bootstrap host shims made redundant by extern packages**

The following F# host shim projects were made redundant when their libraries migrated to `extern package` declarations. Delete them:

- `bootstrap/src/Lyric.Mail.Host/` — replaced by `extern package MailKit.Net.Smtp` in `lyric-mail`
- `bootstrap/src/Lyric.Mq.Host/` — replaced by `extern package RabbitMQ.Client` in `lyric-mq`

Retain:
- `bootstrap/src/Lyric.Session.Host/` — until `lyric-session` fully migrates to typed extern boundary (Tier 3 / #1022)
- `bootstrap/src/Lyric.Jobs.Host/` — until `lyric-jobs` fully migrates (Tier 3 / #1022)
- `bootstrap/src/Lyric.Storage.Host/` — until `lyric-storage` fully migrates (Tier 3 / #1022)
- `bootstrap/src/Lyric.Auth.Host/` — `lyric-auth` uses BCL crypto (`System.Security.Cryptography`); retain until a pure-Lyric crypto kernel is designed

**Step 4 — Delete `--internal-build` fallback path**

`bootstrap/src/Lyric.Cli/Program.fs` has an `--internal-build` path that still calls `Lyric.Emitter` types directly. After step 2, this path will fail to compile; remove it. The `--internal-build` flag now routes solely through the self-hosted MSIL pipeline (already wired via `SelfHostedMsil.fs` or equivalent).

**Step 5 — Delete test infrastructure shims that proxied to `Lyric.Emitter`**

In `bootstrap/tests/Lyric.Emitter.Tests/`, remove any test helpers that called `Lyric.Emitter.Emitter.emit` or similar. All tests must now drive the self-hosted pipeline via `SelfHostedMsil.fs` / `SelfHostedJvm.fs`.

If any test in `Lyric.Emitter.Tests` cannot run via the self-hosted pipeline (because the feature it covers is not yet implemented in the self-hosted emitter), do **not** delete the test — file a tracked issue and gate the test with `pending` / `ptestCase` until the self-hosted pipeline supports it. Do not skip or ignore it silently.

**Step 6 — Update `scripts/bootstrap.sh`**

Stage 1 of `bootstrap.sh` still invokes `dotnet run --project bootstrap/src/Lyric.Cli/ --internal-build`. After removing `--internal-build` from `Lyric.Cli`, update stage 1 to use the self-hosted pipeline invocation directly.

Verify: `scripts/bootstrap.sh --stage 1 && scripts/bootstrap.sh --stage 2 && scripts/bootstrap.sh --stage 3` completes without errors and the reproducibility check passes.

**Step 7 — Update documentation**

- `docs/10-bootstrap-progress.md` — mark Band 7 as complete; update all "F# bootstrap emitter" references to reflect the deleted state.
- `docs/23-fsharp-shim-elimination.md` — mark the emitter and all deleted shims as eliminated; update the elimination schedule.
- `docs/05-implementation-plan.md` — mark Phase 1 milestone M1.3 as `ELIMINATED (self-hosted)`.
- `README.md` — remove any mention of `--target dotnet-legacy` or the F# emitter as a fallback.

---

## Acceptance Criteria

- [ ] All tiers 1–9 are merged to `main` before this PR opens (pre-condition verified)
- [ ] `scripts/bootstrap.sh` stage-3 reproducibility check passes before any deletion
- [ ] `--target dotnet-legacy` flag removed from CLI; `lyric build --target dotnet-legacy` exits non-zero with "unknown target" message
- [ ] `bootstrap/src/Lyric.Emitter/` directory deleted entirely
- [ ] `Emitter.fs`, `Weaver.fs`, `TestSynth.fs`, `ProcessCapture.fs`, `Formatter.fs` all gone
- [ ] `bootstrap/src/Lyric.Mail.Host/` deleted
- [ ] `bootstrap/src/Lyric.Mq.Host/` deleted
- [ ] `dotnet build Bootstrap.sln` succeeds with zero errors after all deletions
- [ ] `--internal-build` path in `Program.fs` routes through self-hosted pipeline only
- [ ] `Lyric.Emitter.Tests` all pass via self-hosted pipeline; zero tests use deleted `Lyric.Emitter` types
- [ ] Any test that cannot yet run via self-hosted pipeline is `ptestCase`-gated with a tracking issue, not silently skipped
- [ ] `scripts/bootstrap.sh` stage 1–3 completes; reproducibility check passes after all deletions
- [ ] `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes (zero skipped) after deletions
- [ ] `dotnet run --project bootstrap/tests/Lyric.Cli.Tests` passes (zero skipped) after deletions
- [ ] `lyric test --manifest lyric-stdlib/lyric.toml` passes on `--target dotnet` after deletions
- [ ] `lyric test --manifest lyric-stdlib/lyric.toml` passes on `--target jvm` after deletions
- [ ] `docs/10-bootstrap-progress.md` Band 7 marked complete
- [ ] `docs/23-fsharp-shim-elimination.md` deletion schedule updated
- [ ] `docs/05-implementation-plan.md` M1.3 marked `ELIMINATED (self-hosted)`
- [ ] `README.md` has no remaining references to `--target dotnet-legacy` or F# emitter fallback
- [ ] No new F# code of any kind added in this PR (this is a deletion-only PR)
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
