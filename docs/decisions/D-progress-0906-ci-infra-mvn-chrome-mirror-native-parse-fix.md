# D-progress-906 — CI infra: Maven on self-hosted `compiler-self-tests-jvm`, avoid the Chrome apt-mirror flake, and fix the `llvm_codegen_self_test.l` parse error hiding native-backend test results (#7038, #7080, #7081)

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
   `make maven-resolver`), mirroring the exact
   `if: runner.environment == 'self-hosted'` pattern
   `native-backend-self-tests` already uses for its clang/gcc install,
   and matching the explicit Maven install `manual-test.yml` already
   uses for the same JVM-dependency-resolution need.
2. **Chrome apt mirror**: prefixed every `apt-get update` invocation in
   `ci.yml` (the three z3 installs, the self-hosted clang/gcc/ASan
   install, the native-AOT-linker clang install, and the Native-AOT-e2e
   clang install — six sites total, including the new Maven step above)
   with `sudo rm -f /etc/apt/sources.list.d/google-chrome.list*`. This
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
workflow-file change can fix. It's also not a full audit of every
`apt-get`/toolchain-install step against every possible transient
mirror flake — just the two concretely observed here.
