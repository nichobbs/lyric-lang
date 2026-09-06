#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# detect-code-changes.sh — determine whether the diff touches non-docs code,
# compiler/runtime core, one specific backend (MSIL/JVM/native), or
# JVM-ecosystem kernels, and emit the per-library ecosystem-tests run map.
# Backs the "Detect code changes" step's has_code_changes / has_core_changes
# / has_msil_changes / has_jvm_changes / has_native_changes / run_map
# outputs.
#
# Reads (set by the calling step's `env:` block from GitHub Actions
# context expressions, since this script -- unlike an inline `run: |`
# block -- is not itself subject to `${{ }}` substitution):
#   EVENT_NAME        github.event_name
#   PR_BASE_SHA       github.event.pull_request.base.sha
#   PR_HEAD_SHA       github.event.pull_request.head.sha
#   PUSH_BEFORE_SHA   github.event.before
# GITHUB_SHA (== github.sha) and GITHUB_OUTPUT are default Actions env vars.
#
# Extracted from ci.yml's "Detect code changes" step (#6387/
# check-workflow-size.sh — see scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ "$EVENT_NAME" = "pull_request" ]; then
  BASE_SHA="$PR_BASE_SHA"
  HEAD_SHA="$PR_HEAD_SHA"
else
  BASE_SHA="$PUSH_BEFORE_SHA"
  HEAD_SHA="$GITHUB_SHA"
fi

# Shared core-infra prefix: anything here can change what every
# ecosystem-tests matrix entry does (the manifest chain, or how
# it's invoked) regardless of which library's own directory
# changed, so it must appear in EVERY entry's trigger pattern
# below, not just the has_core_changes check further down. A
# ci.yml-only change (like this PR's own diff) is the case that
# would otherwise silently zero out the whole matrix.
CORE_INFRA_PATTERN='lyric-compiler/|lyric-stdlib/|bootstrap/|lyric-rt/|resolver/|scripts/|Makefile|\.github/workflows/ci\.yml'

# Per-ecosystem-library dependency map backing the `ecosystem-tests`
# matrix (split from the old monolithic `ecosystem-security-tests`
# job). Each id names one lyric-<id>/ library; the value lists the
# OTHER lyric-<dep>/ directories that library's own test-manifest
# chain actually path-depends on, transcribed from the build-order
# comments that used to live inline in that job. `emit_run_map`
# below turns this into a JSON {id: true|false} map: a PR touching
# only an unrelated library's directory skips that matrix entry; a
# compiler/stdlib/core-infra change (per CORE_INFRA_PATTERN above)
# always triggers every entry.
declare -A ECO_DEPS=(
  [auth]=""
  [session]="cache"
  [health]=""
  [cache]=""
  [docker]=""
  [mail]=""
  [aws-xray]=""
  [aws-secrets]=""
  [feature-flags]=""
  [validation]=""
  [storage]=""
  [proto]=""
  [otel]="proto"
  [jsonrpc]=""
  [mcp]="jsonrpc"
  [logging]=""
  [mq]="cache"
  [grpc]="auth resilience"
  [db]="logging"
  [search]="resilience"
  [lambda]="auth resilience web"
  [web]="auth resilience"
  [ws]="auth"
  [testing]="cache mail storage feature-flags mq session"
)

# $1: "true" forces every entry to true (conservative fallback /
# first push); otherwise $2 is the newline-separated changed-file
# list to grep each entry's trigger pattern against. Builds the
# JSON via an array + IFS join rather than manual comma bookkeeping
# so no branch of this loop can trip the shell's default `-e`.
emit_run_map() {
  local force_true="$1"
  local files="$2"
  local id dep pattern val
  local entries=()
  for id in "${!ECO_DEPS[@]}"; do
    if [ "$force_true" = "true" ]; then
      val=true
    else
      pattern="^(${CORE_INFRA_PATTERN}|lyric-${id}/"
      for dep in ${ECO_DEPS[$id]}; do
        pattern="${pattern}|lyric-${dep}/"
      done
      pattern="${pattern})"
      if printf '%s\n' "$files" | grep -qE "$pattern"; then
        val=true
      else
        val=false
      fi
    fi
    entries+=("\"${id}\":${val}")
  done
  run_map="{$(IFS=,; echo "${entries[*]}")}"
  echo "run_map=${run_map}" >> "$GITHUB_OUTPUT"
  echo "Ecosystem per-library run map: ${run_map}"
}

# First-ever push to a branch has no parent; treat as code change.
if [ "$BASE_SHA" = "0000000000000000000000000000000000000000" ]; then
  echo "has_code_changes=true" >> "$GITHUB_OUTPUT"
  echo "has_core_changes=true" >> "$GITHUB_OUTPUT"
  echo "has_msil_changes=true" >> "$GITHUB_OUTPUT"
  echo "has_jvm_changes=true" >> "$GITHUB_OUTPUT"
  echo "has_native_changes=true" >> "$GITHUB_OUTPUT"
  emit_run_map true ""
  echo "First push — assuming code changes."
  exit 0
fi

# Skip the full build when only documentation or repository
# metadata files changed.  The filter set is:
#
# * `book/`, `docs/`, `*.md` — narrative docs.
# * `.github/CODEOWNERS`, `.github/PULL_REQUEST_TEMPLATE*`,
#   `.github/ISSUE_TEMPLATE/` — repository metadata that
#   doesn't affect what CI does.  `ci.yml` itself and any
#   shell scripts under `.github/` stay *inside* the build
#   set so that misconfigurations are caught on the same PR
#   they land in, not the next unrelated push.
#
# `pipefail` stays on so a `git diff` failure propagates and
# the outer `|| changed="yes"` fires the safe fallback.  A
# single combined `grep -vE` keeps the pipeline short so the
# `|| true` wrapper only has to absorb one benign exit-1
# (every line filtered out on a docs-only PR); `head -1`
# then sees empty stdin and `changed` ends up empty,
# correctly signalling "skip".
set -o pipefail
changed=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
  | { grep -vE '^(book/|docs/|\.github/(CODEOWNERS|PULL_REQUEST_TEMPLATE|ISSUE_TEMPLATE/))|\.md$' || true; } \
  | head -1) || changed="yes"

if [ -n "$changed" ]; then
  echo "has_code_changes=true" >> "$GITHUB_OUTPUT"
  echo "Code changes detected — full build and test will run."
else
  echo "has_code_changes=false" >> "$GITHUB_OUTPUT"
  echo "Docs-only change — build and test skipped."
fi

# Second, finer-grained signal: does the diff touch the
# compiler/runtime core (CORE_INFRA_PATTERN, declared above:
# lyric-compiler/, lyric-stdlib/, bootstrap/, lyric-rt/,
# resolver/, scripts/, this workflow file, or the root Makefile)?
# Deliberately excludes native/ — that directory holds only *.md
# backend-design planning docs (no code; the real native backend
# lives under lyric-compiler/lyric/llvm_*.l and
# lyric-stdlib/std/_kernel_native/, both already covered), so
# including it would force a rebuild for doc-only edits with
# nothing to actually verify. The compiler self-test,
# native-backend, closure zero-overhead, ilverify, AOT-smoke, and
# e2e-CLI jobs below only ever exercise this surface — a PR that
# touches just one ecosystem library (lyric-web/, lyric-mq/,
# ...), lyric-vscode/, lyric-testing/, or examples/ gains nothing
# from re-running them. Same conservative-fallback shape as the
# has_code_changes check above: any ambiguity (git diff failure,
# first push already handled) resolves to "true" — a missed skip
# costs CI minutes, a wrong skip hides a regression.
core_changed=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
  | { grep -E "^(${CORE_INFRA_PATTERN})" || true; } \
  | head -1) || core_changed="yes"

if [ -n "$core_changed" ]; then
  echo "has_core_changes=true" >> "$GITHUB_OUTPUT"
  echo "Compiler/runtime-core changes detected — compiler/native/JVM/AOT test jobs will run."
else
  echo "has_core_changes=false" >> "$GITHUB_OUTPUT"
  echo "No compiler/runtime-core changes — compiler/native/JVM/AOT test jobs skipped."
fi

# Third signal, split three ways by backend: does the diff touch one
# specific backend's OWN tree, or a SHARED front-/middle-end path
# that every backend's self-tests actually exercise regardless of
# which one it targets (the lexer, parser, type checker, mode
# checker, mono, weaver, pipeline, the stdlib's public Std.* surface,
# bootstrap/, resolver/, scripts/, Makefile, or this workflow file)?
#
#   MSIL   — lyric-compiler/msil/ only. lyric-stdlib/std/_kernel/ is
#            deliberately NOT MSIL-exclusive (see #7015): the self-hosted
#            stdlib loader (emitter.l's findStdlibSourcesForTarget /
#            findStdlibSourcesNative) resolves `_kernel_jvm/`/
#            `_kernel_native/` overrides by BASENAME, falling back to
#            `_kernel/<basename>.l` whenever no target-specific override
#            exists with that basename -- e.g. `_kernel/verifier_env_host.l`
#            and `_kernel/tcp_host.l` have no `_kernel_jvm/` counterpart and
#            compile into the JVM build via fallback; ~13 more basenames
#            (`collections_host.l`, `hash_host.l`, `json_host.l`, …) have no
#            `_kernel_native/` counterpart and feed the native build the
#            same way. Classifying all of `_kernel/` as MSIL-only would set
#            has_msil_changes without has_jvm_changes/has_native_changes for
#            a PR touching only one of those fallback-only basenames,
#            silently skipping compiler-self-tests-jvm/native-backend-self-
#            tests/the JVM numbered shards for a file actually compiled into
#            those targets. `_kernel/` therefore falls through to the
#            shared-path bucket below (it already matches CORE_INFRA_PATTERN
#            via lyric-stdlib/) instead of being pattern-matched here.
#   JVM    — lyric-compiler/jvm/, lyric-stdlib/std/_kernel_jvm/, plus
#            the same lyric-web/storage/resilience/auth condition the
#            old has_jvm_ecosystem_changes carried (compiler-self-
#            tests-jvm is the only CI exercise of those four
#            libraries' JVM kernels/manifests — Storage.Kernel.Jvm,
#            Resilience.Kernel.Jvm, Auth.Kernel.Jvm feature
#            resolution, the lyric-web Undertow end-to-end smoke —
#            none of which the ecosystem-tests matrix duplicates, so
#            folding them into the plain backend-tree pattern instead
#            would silently drop that coverage on a PR confined to
#            just one of those four libraries)
#   native — lyric-compiler/lyric/llvm_*.l, lyric-stdlib/std/
#            _kernel_native/, lyric-rt/
#
# A diff confined to exactly one backend's own tree sets only that
# backend's flag; a diff touching anything else CORE_INFRA_PATTERN
# covers (i.e. a shared path) sets all three. That makes
# has_msil_changes || has_jvm_changes || has_native_changes a
# superset of has_core_changes — equal to it for any diff that
# doesn't touch lyric-web/storage/resilience/auth, but has_jvm_changes
# can independently be true from just those four ecosystem libraries
# (the carried-over has_jvm_ecosystem_changes condition) even when
# has_core_changes is false. No coverage is lost overall relative to
# the old has_core_changes-gated jobs; it is only reordered onto the
# backend(s) actually affected, plus that one pre-existing ecosystem
# carve-out. Deliberately
# conservative at the file-NAME level: a handful of backend-specific
# `*_msil_self_test.l` / `*_jvm_self_test.l` files live directly
# inside the shared lyric-compiler/lyric/ directory by long-standing
# convention (they also exercise shared front-end machinery); they
# are treated as shared here rather than pattern-matched by filename,
# so they keep running on every core change exactly as before this
# split — same conservative-fallback shape as has_code_changes and
# has_core_changes above: any ambiguity resolves to "true".
MSIL_ONLY_PATTERN='lyric-compiler/msil/'
JVM_ONLY_PATTERN='lyric-compiler/jvm/|lyric-stdlib/std/_kernel_jvm/'
NATIVE_ONLY_PATTERN='lyric-compiler/lyric/llvm_[^/]*\.l$|lyric-stdlib/std/_kernel_native/|lyric-rt/'
BACKEND_ONLY_PATTERN="${MSIL_ONLY_PATTERN}|${JVM_ONLY_PATTERN}|${NATIVE_ONLY_PATTERN}"

backend_files=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null) && backend_ok=1 || backend_ok=0

if [ "$backend_ok" -eq 1 ]; then
  shared_changed=$(printf '%s\n' "$backend_files" \
    | { grep -E "^(${CORE_INFRA_PATTERN})" || true; } \
    | { grep -vE "^(${BACKEND_ONLY_PATTERN})" || true; } \
    | head -1)
  msil_changed=$(printf '%s\n' "$backend_files" \
    | { grep -E "^(${MSIL_ONLY_PATTERN})" || true; } | head -1)
  jvm_changed=$(printf '%s\n' "$backend_files" \
    | { grep -E "^(${JVM_ONLY_PATTERN}|lyric-web/|lyric-storage/|lyric-resilience/|lyric-auth/)" || true; } | head -1)
  native_changed=$(printf '%s\n' "$backend_files" \
    | { grep -E "^(${NATIVE_ONLY_PATTERN})" || true; } | head -1)
else
  shared_changed="yes"
  msil_changed="yes"
  jvm_changed="yes"
  native_changed="yes"
fi

if [ -n "$shared_changed" ] || [ -n "$msil_changed" ]; then
  echo "has_msil_changes=true" >> "$GITHUB_OUTPUT"
  echo "MSIL-relevant changes detected — MSIL-specific test jobs will run."
else
  echo "has_msil_changes=false" >> "$GITHUB_OUTPUT"
  echo "No MSIL-relevant changes — MSIL-specific test jobs skipped."
fi

if [ -n "$shared_changed" ] || [ -n "$jvm_changed" ]; then
  echo "has_jvm_changes=true" >> "$GITHUB_OUTPUT"
  echo "JVM-relevant changes detected — JVM-specific test jobs will run."
else
  echo "has_jvm_changes=false" >> "$GITHUB_OUTPUT"
  echo "No JVM-relevant changes — JVM-specific test jobs skipped."
fi

if [ -n "$shared_changed" ] || [ -n "$native_changed" ]; then
  echo "has_native_changes=true" >> "$GITHUB_OUTPUT"
  echo "Native-backend-relevant changes detected — native test jobs will run."
else
  echo "has_native_changes=false" >> "$GITHUB_OUTPUT"
  echo "No native-backend-relevant changes — native test jobs skipped."
fi

# Finally, the per-library run map itself (a fresh `git diff` call,
# independent of the `changed`/`core_changed` computations above so
# a grep quirk in either can't affect this one).
eco_files=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null) && eco_ok=1 || eco_ok=0
if [ "$eco_ok" -eq 1 ]; then
  emit_run_map false "$eco_files"
else
  emit_run_map true ""
fi

