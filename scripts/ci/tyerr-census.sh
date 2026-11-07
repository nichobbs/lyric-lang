#!/usr/bin/env bash
# Print the silent-TyError census (I0001, D341) from the stage 2 emit log.
set -euo pipefail
log="${1:-.bootstrap/stage2-emit.log}"
[[ -f "$log" ]] || { echo "tyerr-census: missing $log" >&2; exit 1; }
n=$(grep -c 'I0001' "$log" || true)
echo "::notice::I0001 silent TyError sites in the compiler and stdlib closure: ${n}"
sites=$(grep 'I0001' "$log" | sort -u || true)
printf '%s\n' "$sites" | head -2000
total=$(printf '%s\n' "$sites" | grep -c . || true)
if [[ "$total" -gt 2000 ]]; then echo "tyerr-census: $((total - 2000)) more sites not printed"; fi
