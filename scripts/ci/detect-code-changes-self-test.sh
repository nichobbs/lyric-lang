#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# detect-code-changes-self-test.sh — smoke-test the backend-split regex
# logic in detect-code-changes.sh (has_msil_changes / has_jvm_changes /
# has_native_changes) against a disposable git repo.
#
# A wrong pattern here fails *silently* in real CI: the affected job just
# doesn't run, with no red X anywhere to point at. This script exists so a
# future edit to MSIL_ONLY_PATTERN / JVM_ONLY_PATTERN / NATIVE_ONLY_PATTERN
# (or to the lyric-web/storage/resilience/auth JVM-ecosystem carve-out) gets
# caught by CI instead of quietly under-testing some backend — see the
# claude-review SUGGESTION on #6997 this was written to close.
#
# Builds one throwaway git repo with a base commit, then for each case below
# makes a single-file change on top of that base, runs detect-code-changes.sh
# against (base, case) as a plain push event, and asserts the three backend
# flags plus has_core_changes match what's expected. Exits non-zero on the
# first mismatch, printing every flag detect-code-changes.sh emitted.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.email "test@example.com"
git -C "$WORKDIR" config user.name "detect-code-changes-self-test"

# detect-code-changes.sh resolves its own REPO_ROOT from
# ${BASH_SOURCE[0]}'s on-disk location (two directories up), not from the
# caller's cwd -- it always cds there before running `git diff`, since real
# CI invocations are already at the repo root and that cd is a no-op safety
# net there. To exercise it against this disposable repo instead of the real
# one, copy it in at the same relative path so BASH_SOURCE resolves to
# $WORKDIR.
mkdir -p "$WORKDIR/scripts/ci"
cp "$REPO_ROOT/scripts/ci/detect-code-changes.sh" "$WORKDIR/scripts/ci/detect-code-changes.sh"
SCRIPT="$WORKDIR/scripts/ci/detect-code-changes.sh"

mkdir -p "$WORKDIR/lyric-compiler/msil" "$WORKDIR/lyric-compiler/jvm" \
  "$WORKDIR/lyric-compiler/lyric" "$WORKDIR/lyric-stdlib/std/_kernel" \
  "$WORKDIR/lyric-stdlib/std/_kernel_jvm" "$WORKDIR/lyric-stdlib/std/_kernel_native" \
  "$WORKDIR/lyric-stdlib/std/_kernel_native_bogus" "$WORKDIR/lyric-rt" \
  "$WORKDIR/lyric-web" "$WORKDIR/lyric-storage" "$WORKDIR/lyric-resilience" \
  "$WORKDIR/lyric-auth"
echo base >"$WORKDIR/README.md"
git -C "$WORKDIR" add -A
git -C "$WORKDIR" commit -q -m base
BASE_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"

# name | changed file | expected msil,jvm,native,core (t/f each)
CASES=(
  "msil-only|lyric-compiler/msil/foo.l|t,f,f,t"
  "kernel-shared-not-msil-only|lyric-stdlib/std/_kernel/foo.l|t,t,t,t"
  "jvm-only|lyric-compiler/jvm/foo.l|f,t,f,t"
  "jvm-kernel|lyric-stdlib/std/_kernel_jvm/foo.l|f,t,f,t"
  # Regression guard for #7015: _kernel/ files with no per-target override
  # (real example, not a synthetic basename) load into JVM/native builds
  # via emitter.l's basename fallback, so a diff confined to one of them
  # must NOT set has_msil_changes alone.
  "kernel-asymmetric-basename-fallback|lyric-stdlib/std/_kernel/verifier_env_host.l|t,t,t,t"
  "native-only|lyric-compiler/lyric/llvm_foo.l|f,f,t,t"
  "native-kernel|lyric-stdlib/std/_kernel_native/foo.l|f,f,t,t"
  "native-rt|lyric-rt/foo.c|f,f,t,t"
  "near-miss-kernel-native-bogus|lyric-stdlib/std/_kernel_native_bogus/foo.l|t,t,t,t"
  "jvm-ecosystem-web|lyric-web/foo.l|f,t,f,f"
  "jvm-ecosystem-storage|lyric-storage/foo.l|f,t,f,f"
  "jvm-ecosystem-resilience|lyric-resilience/foo.l|f,t,f,f"
  "jvm-ecosystem-auth|lyric-auth/foo.l|f,t,f,f"
  "shared-front-end|lyric-compiler/lyric/parser.l|t,t,t,t"
  "docs-only|docs/README-scratch.md|f,f,f,f"
)

fail=0
for case in "${CASES[@]}"; do
  IFS='|' read -r name file expect <<<"$case"
  IFS=',' read -r exp_msil exp_jvm exp_native exp_core <<<"$expect"

  git -C "$WORKDIR" checkout -q "$BASE_SHA"
  mkdir -p "$WORKDIR/$(dirname "$file")"
  echo "change for $name" >"$WORKDIR/$file"
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" commit -q -m "$name"
  HEAD_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"

  OUT_FILE="$(mktemp)"
  (
    cd "$WORKDIR"
    EVENT_NAME=push \
      PR_BASE_SHA="" PR_HEAD_SHA="" \
      PUSH_BEFORE_SHA="$BASE_SHA" GITHUB_SHA="$HEAD_SHA" \
      GITHUB_OUTPUT="$OUT_FILE" \
      bash "$SCRIPT" >/dev/null
  )

  got_msil=$(grep -q '^has_msil_changes=true$' "$OUT_FILE" && echo t || echo f)
  got_jvm=$(grep -q '^has_jvm_changes=true$' "$OUT_FILE" && echo t || echo f)
  got_native=$(grep -q '^has_native_changes=true$' "$OUT_FILE" && echo t || echo f)
  got_core=$(grep -q '^has_core_changes=true$' "$OUT_FILE" && echo t || echo f)
  rm -f "$OUT_FILE"

  if [ "$got_msil" != "$exp_msil" ] || [ "$got_jvm" != "$exp_jvm" ] \
    || [ "$got_native" != "$exp_native" ] || [ "$got_core" != "$exp_core" ]; then
    echo "FAIL: $name ($file)"
    echo "  expected msil=$exp_msil jvm=$exp_jvm native=$exp_native core=$exp_core"
    echo "  got      msil=$got_msil jvm=$got_jvm native=$got_native core=$got_core"
    fail=1
  else
    echo "ok:   $name"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "detect-code-changes-self-test.sh: one or more backend-split cases FAILED" >&2
  exit 1
fi

echo "detect-code-changes-self-test.sh: all ${#CASES[@]} cases passed"
