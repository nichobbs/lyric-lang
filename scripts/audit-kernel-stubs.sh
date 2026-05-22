#!/usr/bin/env bash
# audit-kernel-stubs.sh — guard rail for #733.
#
# PR #687 ("fix all 24 Lyric libraries to compile successfully") replaced
# real `extern package` declarations in eight ecosystem libraries with
# stub bodies (`= Ok(0)` / `= Err("not linked")` / `Unit = ()`).  The
# affected libraries (lyric-mq / session / ws / mail / jobs / storage /
# aws-secrets / web) compile and pass tests but are silent no-ops at
# runtime.  See #733 and its eight tracking sub-issues (#777-#784).
#
# This script enforces: **no NEW stub bodies may be added** to any
# `_kernel/net/*.l` file on the current branch.  The existing stubs are
# tracked separately; they're removed incrementally by the restoration
# PRs.  This audit only fires on regressions.
#
# Compares HEAD against an upstream base ref (defaults to origin/main).
# Exits 0 if no new stubs were added, 1 otherwise.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_ref="${LYRIC_KERNEL_STUB_BASE:-origin/main}"

# Resolve the merge base so we only see commits introduced on this branch.
if ! base_sha=$(git merge-base HEAD "$base_ref" 2>/dev/null); then
  echo "kernel-stub audit: no merge-base with $base_ref — skipping (probably first push)"
  exit 0
fi

# Stub-body patterns introduced by #687.
patterns=(
  '= Ok\(0\)'
  '= Ok\(""\)'
  '= Ok\(\(\)\)'
  '= Ok\(false\)'
  '= Err\("[^"]*not linked"\)'
  ': Unit = \(\)'
)
joined=$(IFS='|'; echo "${patterns[*]}")

# Walk a unified-0 diff of every `_kernel/net/*.l` file changed on this
# branch and grep for lines starting with `+` whose body matches a stub
# pattern.  The leading-`+` filter alone restricts us to additions; the
# `(pub )?func` prefix catches both public and private stub declarations.
added_stubs=$(git diff "$base_sha"..HEAD --unified=0 \
  -- 'lyric-*/src/_kernel/net/*.l' 2>/dev/null \
  | grep -E "^\+[[:space:]]*(pub[[:space:]]+)?func.*($joined)" \
  || true)

if [ -n "$added_stubs" ]; then
  echo "::error::New kernel stub body introduced on this branch — see #733."
  echo "         _kernel/net/*.l files must declare 'extern package { ... }'"
  echo "         blocks or '@externTarget(\"…\")' annotations, not stub bodies."
  echo
  echo "$added_stubs" | sed 's/^/    /'
  cat <<'NOTE'

Reference:
  - lyric-auth/src/_kernel/net/auth_kernel.l  (extern package template)
  - lyric-*/src/_kernel/jvm/*_kernel.l        (contract signatures)

If a stub kernel is genuinely needed for an offline / feature-gated
path, route it through a file outside `_kernel/net/` or document the
exception in the issue thread for #733.
NOTE
  exit 1
fi

echo "kernel-stub audit: clean (no new stubs vs $base_ref)"
exit 0
