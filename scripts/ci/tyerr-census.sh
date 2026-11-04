#!/usr/bin/env bash
# Print the silent-TyError census (W0036, D341) from the stage 2 emit log.
set -euo pipefail
log="${1:-.bootstrap/stage2-emit.log}"
[[ -f "$log" ]] || { echo "tyerr-census: missing $log" >&2; exit 1; }
n=$(grep -c 'W0036' "$log" || true)
echo "::notice::W0036 silent TyError sites in the compiler and stdlib closure: ${n}"
grep 'W0036' "$log" | sort -u | head -2000 || true
