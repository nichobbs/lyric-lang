# D-progress-887 — Addendum to D-progress-543: published NuGet `lyric` 0.6.2's `lyric fmt --write` corrupted a space-character string literal to a NUL byte

**Status:** shipped

**Context.** D-progress-543 documents the sandbox exception allowing a session
without a from-source `./bin/lyric` build to fall back to the published NuGet
`lyric` global tool, plus the verification bar for treating that tool's
`lyric fmt` output as untrustworthy (isolate a reformat run to code outside
the actual diff). This addendum records a further divergence found while
formatting `lyric-aws-secrets/src/_kernel/secrets_kernel_jvm.l` for #5411's
PR (see D-progress-886) — worse than a style disagreement, this one is a
**literal-content corruption**.

**Finding.** `lyric fmt --write` (NuGet `lyric` 0.6.2, `dotnet tool install -g
lyric`) on a file containing `name + " " + k` (a plain space-character string
literal used as a cache-key separator) rewrote the formatted output to
`name + "\u{0000}" + k` — silently changing a space character into a NUL
byte, a different runtime value, not merely different formatting. The same
run also reproduced the already-documented match-block-collapse divergence
(a multi-line `match key { case Some(k) -> ...; case None -> ... }`
collapsed to single-line semicolon form) on the same file. Per D-progress-543's
condition 1 ("isolate a reformat run to code outside the actual diff" is the
verification bar), this divergence needs no such isolation — the tool's own
output for a literal it was handed is provably wrong independent of
surrounding context.

**Resolution.** Not verified against a from-source `./bin/lyric` build at the
time this was found (the same GitHub-access sandbox restriction that made the
NuGet tool necessary also blocked building `./bin/lyric` to check) — it may
have been a stale-published-tool artifact already fixed on `main`, or a live
bug. A later session in this same PR's history obtained a working `lyric`
installation, re-ran `lyric fmt --write` on the affected files, and did
**not** reproduce the corruption (0 NUL bytes, clean re-format) — so this is
most likely resolved on `main`/in the published tool as of this PR's merge,
consistent with the 0.4.14 case D-progress-543 itself documents as having
turned out to be a stale artifact. No compiler-side fix was needed from this
investigation; noted here for the historical record per D-progress-543's own
convention of tracking sandbox-tooling divergences.

**Related:** D-progress-543 (the sandbox exception and verification-bar
convention this addends), D-progress-886 (the PR this was found during),
#5084/D-progress-596 (the analogous 0.4.14 stale-artifact precedent this
addendum's resolution mirrors).
