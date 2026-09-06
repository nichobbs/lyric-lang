# D-progress-887 — #6263 (partial): native `-O` level now defaults from the build profile axis

**Status:** shipped


**Scope decision.** #6263 bundles two independent asks: (1) thread the
resolved `BuildProfile` through to backend codegen so `--release` has *some*
observable effect beyond the `build_profile` define, and (2) decide — as an
explicit language-semantics call, not just plumbing — whether integer
overflow should wrap under `--release` and panic under `--debug` (as
`docs/01-language-reference.md` §2 currently describes) or whether the
reference should be corrected to say overflow always panics regardless of
profile.

This entry closes (1) for the one target where it's a clean, safe,
independently-testable change — native's clang `-O` level — and explicitly
leaves (2) open rather than rushing it. Investigating the overflow claim
empirically (a runtime `Int64.MaxValue + 1` on `--target dotnet`) produced an
inconclusive/surprising result (neither a clean wrap to `Int64.MinValue` nor
a panic) that needs dedicated root-causing before any decision-log entry
about overflow semantics can be trusted — asserting a conclusion here off one
quick probe would be worse than leaving the question open. **#6263 stays
open** for the overflow half; do not close it on this entry alone.

**What shipped.** `Lyric.LlvmBridge.linkAndEmitNative` has always defaulted
an empty `optLevel` to a hardcoded `"2"`, with no profile input at all — a
bare `lyric build --target native file.l` (implicit `--debug` profile) and
`lyric build --release --target native file.l` produced identically
optimized binaries. `cli/cli_build.l` gained `resolveNativeOptDefault`
(`pub`, unit-tested directly): explicit `--opt` wins, then the manifest's
`[native] opt_level`, then — only when neither says anything — the profile
axis: `release` → `"2"` (unchanged from the old hardcoded default),
`debug` (the default profile) → `"0"`. Resolved once at `cmdBuild`'s
single-file dispatch (the only place with both a resolved `BuildProfile` and
the native target check), threaded into both the immediate build call and
the `--watch` loop's `BuildFile` record — `buildOneNativeWithFeatures`
itself keeps its existing signature and its own internal `""`-passthrough
behavior unchanged.

**Why this is safe despite changing a default.** `lyric build --target
native <file>` with no `--release`/`--opt`/manifest override now compiles at
`-O0` instead of `-O2` — a genuine, intentional behavior change matching
the language reference's already-designed profile axis (docs/63 §5.2
Q-BP-003). It does not, however, touch any of this repo's ~166 existing
native self-test cases: every one of them calls `Lyric.Cli.buildOneNative`/
`buildOneNativeWithFeatures` directly with an explicit `""` opt string,
never through `cmdBuild`'s argv-parsing layer — so they keep hitting the
original hardcoded `linkAndEmitNative` default unchanged. Only a build that
actually goes through the CLI's `--target native` dispatch is affected,
which is exactly the surface `#6263` asks to fix.

**Verification.** Five new `cli_build_self_test.l` cases pin
`resolveNativeOptDefault`'s full precedence table (explicit `--opt` >
manifest `[native] opt_level` > profile default; non-Native targets are a
no-op) — pure-function tests, no clang/lyric-rt dependency, so they run in
the standard `make self-test NAME=cli_build` loop rather than needing the
native-backend CI job.

**Related:** #6263 (stays open — overflow semantics undecided),
`docs/63-build-profiles-and-debugger.md` §3.1/§5.2 (the profile axis this
extends), `docs/01-language-reference.md` §13.1 (native build defaults),
`lyric-compiler/lyric/llvm_bridge.l` (`linkAndEmitNative`'s pre-existing
hardcoded default, now only reached when nothing upstream supplies a
value).
