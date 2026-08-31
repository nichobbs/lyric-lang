#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# detect-code-changes.sh — determine whether the diff touches non-docs code,
# compiler/runtime core, or JVM-ecosystem kernels, and emit the per-library
# ecosystem-tests run map. Backs the "Detect code changes" step's
# has_code_changes / has_core_changes / has_jvm_ecosystem_changes /
# run_map outputs.
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
  echo "has_jvm_ecosystem_changes=true" >> "$GITHUB_OUTPUT"
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

# compiler-self-tests-jvm's own gate: a superset of has_core_changes.
# Unlike the other 12 has_core_changes-gated jobs, this one also
# contains the ONLY CI exercise of four ecosystem libraries' JVM
# kernels/manifests — Storage.Kernel.Jvm, Resilience.Kernel.Jvm, the
# Auth.Kernel.Jvm feature-resolution build, and the lyric-web
# Undertow end-to-end smoke (tests/jvm_server_smoke.l) — none of
# which the ecosystem-tests matrix duplicates (it only runs their
# default/dotnet manifests). Folding lyric-web/storage/resilience/
# auth into the shared has_core_changes pattern instead would have
# over-broadened the OTHER 12 jobs' gates for libraries they never
# touch, so this is a separate, job-specific signal.
jvm_ecosystem_changed=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
  | { grep -E "^(${CORE_INFRA_PATTERN}|lyric-web/|lyric-storage/|lyric-resilience/|lyric-auth/)" || true; } \
  | head -1) || jvm_ecosystem_changed="yes"

if [ -n "$jvm_ecosystem_changed" ]; then
  echo "has_jvm_ecosystem_changes=true" >> "$GITHUB_OUTPUT"
  echo "Compiler-core or web/storage/resilience/auth JVM-kernel changes detected — compiler-self-tests-jvm will run."
else
  echo "has_jvm_ecosystem_changes=false" >> "$GITHUB_OUTPUT"
  echo "No compiler-core or web/storage/resilience/auth changes — compiler-self-tests-jvm skipped."
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

