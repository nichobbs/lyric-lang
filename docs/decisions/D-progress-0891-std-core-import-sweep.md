# D-progress-891 — Sweep: explicit `import Std.Core` added tree-wide ahead of #6287 item 2 (#6703)

**Status:** shipped

**Context.** #6287's "item 2" (rejecting bare-name resolution to a package
reachable in the same multi-file build but not on any import path from the
consumer) was implemented and reverted in PR #6547: a full audit build
surfaced `Option`/`Result` (`Std.Core`) referenced across wide swaths of the
stdlib and ecosystem libraries with no explicit `import Std.Core` at all —
an implicit-prelude reliance far broader than the kernel/host re-export
idiom the original issue anticipated. #6703 asked for the sweep PR #6547
didn't have time to finish, so item 2 can land with zero false positives.

**Sweep scope and result.** Grepped every `lyric-stdlib/std/**/*.l` and
every ecosystem library's `src/**/*.l` for `Option[`/`Result[`/`Some(`/
`None(`/`Ok(`/`Err(` usage without an explicit `import Std.Core`, excluding
comment-only matches. Of 154 files using these names, 8 had a genuine
code-level gap (3 were comment-only false positives; `core.l` itself is
`Std.Core`'s own declaration and correctly excluded): `lyric-stdlib/std/
stream.l`, `_kernel/jvm.l`, `environment.l`, `app.l`, `directory.l`,
`lyric-aws-secrets/src/_kernel/secrets_kernel_{jvm,aws}.l`, `lyric-mail/
src/_kernel/jvm/mail_kernel.l`. Added `import Std.Core` to each. The
self-hosted compiler's own `lyric-compiler/` tree had zero gaps (already
disciplined). Also checked every `Std.Core` function beyond the `Option`/
`Result` types themselves (`unwrapOr`/`isSome`/`isNone`/`isOk`/`isErr`/
`mapOption`/`mapResult`/`andThen`/`orElse`/`unwrapResult`/`unwrapOption`) —
zero additional gaps.

**Correction (review round, #6998).** A `claude-review` pass on this PR
caught a 9th genuine gap the original sweep missed: `lyric-lambda/src/
_kernel/lambda_kernel_web.l` uses `Option[Web.Router]`/`Some(value = ...)`/
`None` in real code with only `import Lambda`/`import Web` declared. This
file was touched by a concurrent `main` commit (lyric-lambda JVM
custom-runtime work, merged after this PR's original sweep ran) that
introduced the gap, so it postdates the sweep's original scan rather than
being an audit miss against the tree as it stood at sweep time. Fixed by
adding `import Std.Core` to that file too — the sweep's true final count
is **9** files, not 8.

**Verification.** `lyric-stdlib/lyric.full.toml` (73 packages) and
`lyric-mail`/`lyric-aws-secrets` all build clean with the added imports
(no behavior change — these are all real, already-reachable dependencies
made explicit, not new functionality). `lyric-lambda` builds clean with
the corrected import too.

**What's NOT done — landing #6287 item 2 itself.** This PR only covers
`lyric-stdlib/` and the ecosystem libraries at the repo root. It does NOT
extend the sweep to `examples/`, `book/` code snippets, or any other
tree that a future item-2 check might touch, and does not attempt to land
the check itself. Given the check's own history (reverted once already for
insufficient audit scope) and that a full safe rollout needs verifying
every consumer of the compiler — not just the ones covered here — actually
landing item 2 needs its own dedicated, fully-audited follow-up PR, not a
bundled addition to this sweep. This PR is the "sweep" half of the
plan `docs/03`'s `D-progress-862` / `#6703` describes; the "land the
check" half remains open.
