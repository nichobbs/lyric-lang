#!/usr/bin/env bash
# check-eco-deps-sync.sh — guardrail for the two hand-maintained
# ecosystem-library dependency tables that back the `build` job's
# change-detection run map and the `ecosystem-tests` job's matrix (#6171).
#
# The `declare -A ECO_DEPS=( [id]="deps" ... )` table (used to compute the
# change-detection run map; lives in scripts/ci/detect-code-changes.sh,
# extracted out of .github/workflows/ci.yml's inline "Detect code changes"
# step to keep the workflow file under its size ceiling — see #6387) and
# the `ecosystem-tests` job's matrix `- id: <id>` / `deps: "<deps>"`
# entries (still inline in ci.yml, used to order per-library
# path-dependency builds) list the same set of libraries and the same
# space-separated dependency strings, but nothing keeps the two in sync
# when a library is added, removed, or has its local-path deps changed.
#
# This script extracts both tables and fails (non-zero exit, printing a
# diff) if the library id sets differ or if any id's dependency string
# differs between the two tables.
#
# Usage:
#   scripts/check-eco-deps-sync.sh [path/to/declare-table-file] [path/to/matrix-table-file]
#
# Defaults to scripts/ci/detect-code-changes.sh (declare table) and
# .github/workflows/ci.yml (matrix table), relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DECLARE_FILE="${1:-$REPO_ROOT/scripts/ci/detect-code-changes.sh}"
MATRIX_FILE="${2:-$REPO_ROOT/.github/workflows/ci.yml}"

if [[ ! -f "$DECLARE_FILE" ]]; then
  echo "error: declare-table file not found: $DECLARE_FILE" >&2
  exit 1
fi
if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "error: matrix-table file not found: $MATRIX_FILE" >&2
  exit 1
fi

# Extract "id=deps" pairs (one per line) from the `declare -A ECO_DEPS=( ... )`
# block: lines shaped like `  [id]="deps"`.
extract_declare_table() {
  local file="$1"
  local in_block=0
  local line id rest deps
  while IFS= read -r line; do
    if [[ $in_block -eq 0 ]]; then
      if [[ "$line" == *"declare -A ECO_DEPS=("* ]]; then
        in_block=1
      fi
      continue
    fi
    # Closing paren on its own (possibly indented) ends the block.
    if [[ "$line" =~ ^[[:space:]]*\)[[:space:]]*$ ]]; then
      in_block=0
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\[([A-Za-z0-9_-]+)\]=\"([^\"]*)\" ]]; then
      id="${BASH_REMATCH[1]}"
      deps="${BASH_REMATCH[2]}"
      printf '%s=%s\n' "$id" "$deps"
    fi
  done < "$file"
}

# Extract "id=deps" pairs from the ecosystem-tests matrix: consecutive
# `          - id: <id>` / `            deps: "<deps>"` line pairs.
extract_matrix_table() {
  local file="$1"
  local line pending_id id deps
  pending_id=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*$ ]]; then
      pending_id="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ -n "$pending_id" && "$line" =~ ^[[:space:]]*deps:[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]]; then
      deps="${BASH_REMATCH[1]}"
      printf '%s=%s\n' "$pending_id" "$deps"
      pending_id=""
    fi
  done < "$file"
}

declare_table="$(extract_declare_table "$DECLARE_FILE")"
matrix_table="$(extract_matrix_table "$MATRIX_FILE")"

if [[ -z "$declare_table" ]]; then
  echo "error: found no entries in the ECO_DEPS declare -A table in $DECLARE_FILE" >&2
  exit 1
fi
if [[ -z "$matrix_table" ]]; then
  echo "error: found no entries in the ecosystem-tests matrix in $MATRIX_FILE" >&2
  exit 1
fi

declare_sorted="$(printf '%s\n' "$declare_table" | sort)"
matrix_sorted="$(printf '%s\n' "$matrix_table" | sort)"

if [[ "$declare_sorted" == "$matrix_sorted" ]]; then
  declare_count="$(printf '%s\n' "$declare_table" | wc -l | tr -d ' ')"
  echo "OK: ECO_DEPS declare table and ecosystem-tests matrix agree ($declare_count entries)."
  exit 0
fi

echo "error: ECO_DEPS declare table ($DECLARE_FILE) and ecosystem-tests matrix ($MATRIX_FILE) disagree" >&2
echo >&2
echo "--- declare -A ECO_DEPS (build job)" >&2
echo "+++ matrix include (ecosystem-tests job)" >&2
diff <(printf '%s\n' "$declare_sorted") <(printf '%s\n' "$matrix_sorted") >&2 || true
echo >&2
echo "Fix: update whichever table is stale so every library id and its" >&2
echo "space-separated deps string match between the two tables." >&2
exit 1
