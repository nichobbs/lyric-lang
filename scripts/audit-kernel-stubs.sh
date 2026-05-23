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
#
# `@externTarget("...")`-annotated declarations are legitimate extern
# bodies (the `= ()` is the language-level convention for "no body, bind
# to the named target") and must be exempted.  The host-shim Phase 4+
# kernels (lyric-mail, lyric-mq, etc.) deliberately use this form.
# Filter them out before applying the stub pattern.
raw_diff=$(git diff "$base_sha"..HEAD --unified=3 \
  -- 'lyric-*/src/_kernel/net/*.l' 2>/dev/null || true)

added_stubs=$(echo "$raw_diff" \
  | awk -v pat="$joined" '
      BEGIN { has_extern = 0 }
      # Track @externTarget annotations seen on context or added lines
      # immediately preceding a func declaration.  Reset whenever we
      # see a non-annotation, non-doc, non-blank line.
      /^[+ ]\s*@externTarget\(/ { has_extern = 1; next }
      /^[+ ]\s*@axiom\(/        { next }            # doc-only — keep state
      /^[+ ]\s*@cfg\(/          { next }            # cfg-only — keep state
      /^[+ ]\s*@stable\(/       { next }            # doc-only — keep state
      /^[+ ]\s*\/\//            { next }            # comment — keep state
      /^[+ ]\s*$/               { next }            # blank — keep state
      /^\+\s*(pub\s+)?func/ {
        if (has_extern == 0) {
          if ($0 ~ pat) print
        }
        has_extern = 0
        next
      }
      # Any other line resets the extern-marker state.
      { has_extern = 0 }
    ' \
  | grep -E "($joined)" \
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
