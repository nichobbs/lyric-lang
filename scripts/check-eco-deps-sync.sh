#!/usr/bin/env bash
# check-eco-deps-sync.sh — guardrail for the two hand-maintained
# ecosystem-library dependency tables in .github/workflows/ci.yml (#6171).
#
# The `build` job's `declare -A ECO_DEPS=( [id]="deps" ... )` table (used
# to compute the change-detection run map) and the `ecosystem-tests` job's
# matrix `- id: <id>` / `deps: "<deps>"` entries (used to order per-library
# path-dependency builds) list the same set of libraries and the same
# space-separated dependency strings, but nothing keeps the two in sync
# when a library is added, removed, or has its local-path deps changed.
#
# This script extracts both tables from the workflow file and fails
# (non-zero exit, printing a diff) if the library id sets differ or if
# any id's dependency string differs between the two tables.
#
# Usage:
#   scripts/check-eco-deps-sync.sh [path/to/ci.yml]
#
# Defaults to .github/workflows/ci.yml relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI_YML="${1:-$REPO_ROOT/.github/workflows/ci.yml}"

if [[ ! -f "$CI_YML" ]]; then
  echo "error: workflow file not found: $CI_YML" >&2
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

declare_table="$(extract_declare_table "$CI_YML")"
matrix_table="$(extract_matrix_table "$CI_YML")"

if [[ -z "$declare_table" ]]; then
  echo "error: found no entries in the ECO_DEPS declare -A table in $CI_YML" >&2
  exit 1
fi
if [[ -z "$matrix_table" ]]; then
  echo "error: found no entries in the ecosystem-tests matrix in $CI_YML" >&2
  exit 1
fi

declare_sorted="$(printf '%s\n' "$declare_table" | sort)"
matrix_sorted="$(printf '%s\n' "$matrix_table" | sort)"

if [[ "$declare_sorted" == "$matrix_sorted" ]]; then
  declare_count="$(printf '%s\n' "$declare_table" | wc -l | tr -d ' ')"
  echo "OK: ECO_DEPS declare table and ecosystem-tests matrix agree ($declare_count entries)."
  exit 0
fi

echo "error: ECO_DEPS declare table and ecosystem-tests matrix disagree in $CI_YML" >&2
echo >&2
echo "--- declare -A ECO_DEPS (build job)" >&2
echo "+++ matrix include (ecosystem-tests job)" >&2
diff <(printf '%s\n' "$declare_sorted") <(printf '%s\n' "$matrix_sorted") >&2 || true
echo >&2
echo "Fix: update whichever table is stale so every library id and its" >&2
echo "space-separated deps string match between the two tables." >&2
exit 1
