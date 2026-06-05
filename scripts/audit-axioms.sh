#!/usr/bin/env bash
# audit-axioms.sh — guardrail for docs/17-axiom-audit.md (#335).
#
# Re-scans every `lyric-stdlib/std/_kernel*/*.l` file for `@axiom("...")`
# annotations and verifies that:
#
#   1. The total counts match the totals declared in
#      `docs/17-axiom-audit.md` section 18.
#   2. Each (platform, package, file, axiom-string) record appears
#      verbatim in the machine-checkable baseline table embedded between
#      `<!-- BEGIN AXIOM BASELINE -->` / `<!-- END AXIOM BASELINE -->`
#      markers in `docs/17-axiom-audit.md` section 19.
#
# Fails the build (exit 1) if either check fails, forcing the audit doc
# to stay in sync with the kernel boundary.  Use `--update` to rewrite
# the baseline section in place after auditing a new axiom.
#
# Usage:
#   scripts/audit-axioms.sh                # CI default — count + baseline check
#   scripts/audit-axioms.sh --list-files   # print every kernel file + axiom presence
#   scripts/audit-axioms.sh --table        # print the structured baseline table to stdout
#   scripts/audit-axioms.sh --update       # rewrite docs/17 baseline in place

set -euo pipefail
shopt -s nullglob

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_DOC="$REPO_ROOT/docs/17-axiom-audit.md"
NET_KERNEL="$REPO_ROOT/lyric-stdlib/std/_kernel"
JVM_KERNEL="$REPO_ROOT/lyric-stdlib/std/_kernel_jvm"
DRIVER="$REPO_ROOT/scripts/audit_axioms_helper.py"

MODE="check"
case "${1:-}" in
  --list-files) MODE="list" ;;
  --table)      MODE="table" ;;
  --update)     MODE="update" ;;
  "")           MODE="check" ;;
  *)            echo "unknown flag: $1" >&2; exit 2 ;;
esac

count_axioms_in_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo 0
    return
  fi
  local files=( "$dir"/*.l )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo 0
    return
  fi
  # Match only `@axiom(` at column 0 (skips comment-mentions like `// see @axiom`).
  # Trim leading whitespace from wc -l output (macOS wc pads with spaces).
  grep -h '^@axiom(' "${files[@]}" 2>/dev/null | wc -l | tr -d ' '
}

list_axiom_files_in_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then return; fi
  for f in "$dir"/*.l; do
    if grep -q '^@axiom(' "$f" 2>/dev/null; then
      echo "  AXIOM  $(basename "$f")"
    else
      echo "  ----   $(basename "$f")"
    fi
  done
}

actual_net=$(count_axioms_in_dir "$NET_KERNEL")
actual_jvm=$(count_axioms_in_dir "$JVM_KERNEL")

case "$MODE" in
  list)
    echo "=== .NET kernel ($NET_KERNEL) ==="
    list_axiom_files_in_dir "$NET_KERNEL"
    echo "  total: $actual_net @axiom-bearing files"
    echo ""
    echo "=== JVM kernel ($JVM_KERNEL) ==="
    list_axiom_files_in_dir "$JVM_KERNEL"
    echo "  total: $actual_jvm @axiom-bearing files"
    exit 0
    ;;
  table)
    python3 "$DRIVER" --table "$REPO_ROOT"
    exit 0
    ;;
  update)
    python3 "$DRIVER" --update "$REPO_ROOT" "$AUDIT_DOC"
    echo "audit-axioms: rewrote §19 baseline ($actual_net .NET + $actual_jvm JVM = $((actual_net + actual_jvm)) records)"
    exit 0
    ;;
esac

# --- count check (default `check` mode) ---

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

# --- baseline check ---
if ! python3 "$DRIVER" --check "$REPO_ROOT" "$AUDIT_DOC"; then
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "audit-axioms: .NET=$actual_net, JVM=$actual_jvm; §18 totals + §19 baseline match the kernel files."
fi

exit $status
