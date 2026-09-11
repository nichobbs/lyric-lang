# D-progress-906 — CI infra: Maven on self-hosted `compiler-self-tests-jvm`, avoid the Chrome apt-mirror flake, fix the `llvm_codegen_self_test.l` parse error hiding native-backend test results, and pin a modern clang on the self-hosted native runner (#7038, #7080, #7081, #7072)

**Status:** shipped

**Context.** While landing an unrelated batch of four disjoint PRs
(#6908, #6871, #6863, #6861), every one of them hit the same three
CI-infrastructure problems, none caused by their own diffs:

1. **`compiler-self-tests-jvm` fails with `mvn: Command not found`**
   (#7038) whenever the job lands on a self-hosted runner. GitHub-hosted
   `ubuntu-latest` images ship Maven preinstalled; the self-hosted image
   does not, and nothing in this workflow explicitly installed it —
   unlike z3/clang, which already have their own explicit install steps.
2. **`apt-get update` intermittently fails with a `Hash Sum mismatch`**
   fetching Google's Chrome apt mirror (#7081, confirmed by @nichobbs as
   reproducing identically on retry). No workflow in this repo adds that
   apt source — it ships pre-added in `actions/runner-images`' hosted
   `ubuntu-latest` image (for headless-Chrome/Chromium test tooling), so
   *any* `apt-get update` on that image refreshes it too, regardless of
   what package is actually being installed (z3, clang, Maven, …).
3. **`native-backend-self-tests` fails/never produces a meaningful
   result** (#7080): `lyric-compiler/lyric/llvm_codegen_self_test.l` has
   had a stray trailing `)` / `}` pair at lines 810-811 since commit
   `81d957c7` (#6916) — a leftover from that PR's manual conflict
   reconstruction. This is a top-level parse error (`P0040: expected an
   item declaration`), so it has silently prevented **every** test in
   the file (not just #6916's own) from running since that commit
   landed, on every PR and on `main` itself.

**Fixes.**

1. **Maven**: added a self-hosted-only install step to
   `compiler-self-tests-jvm` (`.github/workflows/ci.yml`, right before
   the "JVM auto-FFI bridge self-test" step that calls
   `make maven-resolver`), mirroring the
   `if: runner.environment == 'self-hosted'` pattern
   `native-backend-self-tests` already uses for its clang/gcc install,
   and matching the explicit Maven install `manual-test.yml` already
   uses for the same JVM-dependency-resolution need. Unlike that
   clang/gcc step — which is the first step in its job — this one sits
   after ~40 `background: true` steps in `compiler-self-tests-jvm`, so
   it also needs `if: always()` (combined as
   `always() && runner.environment == 'self-hosted'`) or an earlier
   background step's failure skips it by default (#6712/#6788), which
   would reproduce the exact #7038 failure this fix exists to close.
   Caught by review as a REQUIRED finding on the first pass (#7089) and
   fixed before merge.
2. **Chrome apt mirror**: prefixed every `apt-get update` invocation in
   `ci.yml` (the three z3 installs, the self-hosted clang/gcc/ASan
   install, the native-AOT-linker clang install, and the Native-AOT-e2e
   clang install — six pre-existing sites, plus the new Maven step
   above, seven total) with
   `sudo rm -f /etc/apt/sources.list.d/google-chrome.list*`. This
   is a safe, no-op-if-absent removal of an apt source none of these
   steps need, not a checksum bypass — package authentication for
   everything actually being installed is unaffected. Rejected
   alternative: disabling apt's hash/signature verification
   (`Acquire::Check-Valid-Until=false` or similar) would also silently
   accept a genuinely corrupted or tampered package for the packages
   these steps *do* install; removing the one unrelated, flaky source
   is the narrower fix.
3. **`llvm_codegen_self_test.l` parse error**: deleted the stray lines
   810-811. Verified locally (`make lyric` then
   `make self-test NAME=llvm_codegen`, after `make -C lyric-rt` — the
   native runtime static lib self-test needs and the earlier "several
   recently-claimed native fixes are not actually implemented" worry in
   #7080 turned out to be the same missing-prerequisite symptom, not a
   real regression): **47/47 tests pass**, including every one of the
   features #7080 worried might be broken (`lastIndexOf`,
   `trimStart`/`trimEnd`/`replace`, String bracket indexing, String+Char
   concat, and all three #7010 `varIsChar`-shadow-leak cases).
4. **Ancient clang on the self-hosted native runner (#7072)**: fixing
   #3 above let `native-backend-self-tests` run far enough for the first
   time to hit a second masked failure — `llvm_heap_self_test.l` test 35
   ("a NativeWeak async-function result upgrades correctly and is
   leak-free (#5545)") failed in CI with `clang: error: expected '{' in
   function body` on a generated `presplitcoroutine` coroutine function.
   Investigation of the actual failing job log (not just the error
   text) found the self-hosted runner (`coolify-runner-…`, ARM64) is
   still running **clang/lld 10.0** from its distro's default apt repo
   (Ubuntu 20.04 "focal", inferred from the exact package version
   strings in the job log — no `/etc/os-release` dump exists to read
   directly) — 8 major versions behind clang 18 on GitHub-hosted
   `ubuntu-latest` and in local dev. Reproduced the *opposite* result
   locally on clang 18.1.3: the same test passes 39/39. This is not a
   Lyric compiler regression; it's an unpinned toolchain version on one
   machine. Fixed by replacing the plain `apt-get install clang lld`
   with apt.llvm.org's official `llvm.sh` installer pinned to LLVM 18,
   followed by an explicit `apt-get install clang-18 clang++-18 lld-18`
   (`llvm.sh`'s default package set isn't guaranteed to include every
   one of these across script/distro versions, so this guarantees the
   `-18`-suffixed binaries the next step targets actually exist rather
   than assuming), then `update-alternatives` so the bare `clang`/
   `clang++` names — the only ones this compiler's
   `Process.runCapture("clang", …)` call sites in `llvm_bridge.l`
   actually invoke — resolve to the pinned version instead of the
   distro default (`lld`/`ld.lld` are pinned alongside for consistency
   in case clang's own default-linker resolution reaches for them,
   though nothing here invokes either by name directly — corrected
   wording per review, the original comment overclaimed this). Guarded
   by `command -v clang-18` so a persistent self-hosted runner only
   pays the install cost once. **Not verified against the real
   ARM64/focal runner** (unavailable from this environment) —
   correctness of the `llvm.sh 18`/focal/arm64 combination will be
   confirmed by this PR's own CI run; if apt.llvm.org lacks arm64
   packages for LLVM 18 on focal specifically, a follow-up pinning a
   different LLVM major version is the fallback. Running `llvm.sh` as
   root over HTTPS is LLVM's own official install method and a
   reasonable pattern, but worth noting explicitly: unlike an ephemeral
   GitHub-hosted runner, this self-hosted box is persistent, so a
   compromised script here could in principle persist across future
   jobs.

**Verification.** `.github/workflows/ci.yml` parses clean
(`python3 -c "import yaml; yaml.safe_load(...)"`); the six `apt-get`
sites and the new Maven step were reviewed by hand against the existing
self-hosted-only precedent. `llvm_codegen_self_test.l` verified as above
(47/47). Did not run the other eleven `llvm_*_self_test.l` files locally
(unrelated to this fix and unaffected by it — the parse error was
file-local to `llvm_codegen_self_test.l` alone); CI's own
`native-backend-self-tests` job covers them.

**What's NOT done.** This does not address every symptom seen during
the same investigation: the self-hosted runner *capacity* problem
(jobs stuck `queued` for a full 24h then auto-cancelled, tracked
separately as #7087) is a fleet-capacity issue, not something a
workflow-file change can fix. The Chrome-apt-mirror fix (#2 above) is
also only applied to `ci.yml`'s 7 sites — `publish.yml`,
`manual-test.yml`, `seed-candidacy.yml`, and `stage2-self-test.yml`
all also run `apt-get update` on the same hosted-runner image and are
presumably susceptible to the identical flake, tracked as a follow-up
in #7090 rather than bundled into this PR.
