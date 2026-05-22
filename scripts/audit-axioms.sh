#!/usr/bin/env bash
# audit-axioms.sh — guardrail for docs/17-axiom-audit.md (#335).
#
# Re-scans every `lyric-stdlib/std/_kernel*/*.l` file for `@axiom("...")`
# annotations and diffs the counts against the totals declared in
# `docs/17-axiom-audit.md` section 18.  Fails the build if the actual
# count diverges from the documented count, forcing the audit doc to
# stay in sync with the kernel boundary.
#
# Exits 0 when totals match, 1 otherwise (with a per-target diff for
# the failing target).  Designed for CI — no interactive output, no
# colour codes by default.
#
# Usage:
#   scripts/audit-axioms.sh                # CI default — count check only
#   scripts/audit-axioms.sh --list-files   # print every kernel file + axiom presence
#
# Tracked alongside `docs/17-axiom-audit.md`; bump the audit doc's
# totals when adding a new `@axiom`-bearing kernel file, then this
# script will pass.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_DOC="$REPO_ROOT/docs/17-axiom-audit.md"
NET_KERNEL="$REPO_ROOT/lyric-stdlib/std/_kernel"
JVM_KERNEL="$REPO_ROOT/lyric-stdlib/std/_kernel_jvm"

LIST_FILES=0
if [[ "${1:-}" == "--list-files" ]]; then
  LIST_FILES=1
fi

count_axioms_in_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo 0
    return
  fi
  grep -l '@axiom(' "$dir"/*.l 2>/dev/null | wc -l
}

list_axiom_files_in_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then return; fi
  for f in "$dir"/*.l; do
    if grep -q '@axiom(' "$f" 2>/dev/null; then
      echo "  AXIOM  $(basename "$f")"
    else
      echo "  ----   $(basename "$f")"
    fi
  done
}

actual_net=$(count_axioms_in_dir "$NET_KERNEL")
actual_jvm=$(count_axioms_in_dir "$JVM_KERNEL")

if [[ $LIST_FILES -eq 1 ]]; then
  echo "=== .NET kernel ($NET_KERNEL) ==="
  list_axiom_files_in_dir "$NET_KERNEL"
  echo "  total: $actual_net @axiom-bearing files"
  echo ""
  echo "=== JVM kernel ($JVM_KERNEL) ==="
  list_axiom_files_in_dir "$JVM_KERNEL"
  echo "  total: $actual_jvm @axiom-bearing files"
  exit 0
fi

# Extract the documented totals from the audit doc's section 18 tables.
# The .NET totals are the first `| **Total** ... **N** ... **M** |` row
# after the `### .NET kernel` heading; JVM totals are after the
# `### JVM kernel` heading.  We sum stable + provisional per table.
extract_total_after() {
  local heading_pattern="$1"
  awk -v p="$heading_pattern" '
    $0 ~ p { found = 1; next }
    found && /^\| \*\*Total\*\*/ { print; exit }
  ' "$AUDIT_DOC" | grep -oE '\*\*[0-9]+\*\*' | sed 's/[^0-9]//g' \
    | paste -sd+ - | bc 2>/dev/null || echo 0
}

doc_net=$(extract_total_after '^### \.NET kernel ')
doc_jvm=$(extract_total_after '^### JVM kernel ')
doc_net=${doc_net:-0}
doc_jvm=${doc_jvm:-0}

status=0

# Compare.  Note: documented total is `stable + provisional`; actual
# count is `@axiom-bearing files`, which is the same (one @axiom per
# file).
if [[ "$actual_net" != "$doc_net" ]]; then
  echo "::error::audit-axioms: .NET kernel has $actual_net @axiom-bearing files but docs/17 section 18 documents $doc_net"
  echo "  Re-scan: scripts/audit-axioms.sh --list-files"
  echo "  Then update the .NET kernel table in docs/17-axiom-audit.md section 18 to match."
  status=1
fi

if [[ "$actual_jvm" != "$doc_jvm" ]]; then
  echo "::error::audit-axioms: JVM kernel has $actual_jvm @axiom-bearing files but docs/17 section 18 documents $doc_jvm"
  echo "  Re-scan: scripts/audit-axioms.sh --list-files"
  echo "  Then update the JVM kernel table in docs/17-axiom-audit.md section 18 to match."
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "audit-axioms: .NET=$actual_net, JVM=$actual_jvm — both match docs/17 section 18 totals."
fi

exit $status
