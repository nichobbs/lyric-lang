#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-stdlib-cache-e2e.sh: the bundled-stdlib check cache of `--target native` (#7971).
#   - a cold build stores an entry per cacheable package, a second build hits them all;
#   - the LLVM IR is byte-identical with the cache off, cold and warm;
#   - editing one stdlib file invalidates exactly the packages whose import closure holds it;
#   - a corrupt, truncated or foreign entry is ignored (the package is checked in full and the
#     entry rewritten), and the IR is unchanged;
#   - LYRIC_CACHE_DIR=off writes nothing.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/native-stdlib-cache-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export LYRIC_KEEP_LL=1 LYRIC_TRACE_STDLIB_CHECK_CACHE=1
cache="$work/cache"
entries="$cache/native-stdlib-check"

cat > "$work/prog.l" <<'LYRIC'
package Prog
import Std.Console
import Std.Collections
import Std.String
func main(): Unit {
  println("hi")
}
LYRIC

# build <label> [env...]: build prog.l, leaving the trace in $work/<label>.trace and IR in $work/<label>.ll
build() {
  local label="$1"; shift
  env "$@" "$LYRIC_BIN" build --target native "$work/prog.l" -o "$work/$label" 2> "$work/$label.trace" >/dev/null \
    || { cat "$work/$label.trace"; echo "::error::build '$label' failed"; exit 1; }
}
count() { grep -c "stdlib-check-cache: $2 " "$work/$1.trace" || true; }
outcome() { grep "stdlib-check-cache: .* $2\$" "$work/$1.trace" | awk '{print $2}'; }
fail() { echo "::error::$*"; exit 1; }
same_ir() { cmp -s "$work/$1.ll" "$work/$2.ll" || fail "LLVM IR of '$1' and '$2' differ"; }

echo "=== cache off: no entries, baseline IR ==="
build off LYRIC_CACHE_DIR=off
[ ! -e "$cache" ] || fail "LYRIC_CACHE_DIR=off created $cache"
[ "$(count off hit)" = 0 ] || fail "hits with the cache off"

echo "=== cold build stores, warm build hits ==="
build cold LYRIC_CACHE_DIR="$cache"
stored="$(count cold miss-stored)"
[ "$stored" -gt 0 ] || fail "a cold build stored nothing"
[ "$(count cold hit)" = 0 ] || fail "a cold build hit"
[ "$(ls "$entries" | wc -l)" = "$stored" ] || fail "entries on disk do not match the packages stored"
build warm LYRIC_CACHE_DIR="$cache"
[ "$(count warm hit)" = "$stored" ] || fail "a warm build hit $(count warm hit) of $stored packages"
[ "$(count warm miss-stored)" = 0 ] || fail "a warm build re-checked a cached package"
same_ir off cold; same_ir off warm
echo "stored=$stored hit=$(count warm hit)"

echo "=== a stdlib source edit invalidates the package and its dependents only ==="
cp -r lyric-stdlib/std "$work/std"
export LYRIC_STD_PATH="$work/std"
build copy LYRIC_CACHE_DIR="$cache"
[ "$(count copy hit)" = "$stored" ] || fail "a copy of the stdlib at another path must hit: entries are keyed by content, not path"
cp "$work/std/string.l" "$work/string.l.orig"
printf '\n// edited\n' >> "$work/std/string.l"
build edited LYRIC_CACHE_DIR="$cache"
[ "$(outcome edited Std.String)" = "miss-stored" ] || fail "Std.String was not re-checked after an edit"
[ "$(outcome edited Std.Core)" = "hit" ] || fail "Std.Core (outside the edit's dependents) was re-checked"
[ "$(count edited miss-stored)" -ge 1 ] || fail "nothing re-checked"
build edited_again LYRIC_CACHE_DIR="$cache"
[ "$(count edited_again miss-stored)" = 0 ] || fail "the edited stdlib did not become a hit"
cp "$work/string.l.orig" "$work/std/string.l"
build restored LYRIC_CACHE_DIR="$cache"
[ "$(count restored miss-stored)" = 0 ] || fail "restoring the source should hit the original entries"
same_ir restored off
unset LYRIC_STD_PATH

echo "=== corrupt entries fall back to a full check ==="
# A fresh directory, so every entry is one this build reaches (the shared one also holds the
# entries of the edited stdlib above, which this build never looks up).
ccache="$work/cache-corrupt"
centries="$ccache/native-stdlib-check"
build seed LYRIC_CACHE_DIR="$ccache"
[ "$(count seed miss-stored)" = "$stored" ] || fail "the seeding build stored $(count seed miss-stored) of $stored packages"
victims=("$centries"/*.ok)
[ "${#victims[@]}" -ge 5 ] || fail "expected at least 5 entries to damage, found ${#victims[@]}"
: > "${victims[0]}"                                              # empty
head -c 20 "${victims[1]}" > "$work/trunc" && cp "$work/trunc" "${victims[1]}"   # truncated
printf 'garbage' > "${victims[2]}"                               # foreign
cp "${victims[4]}" "${victims[3]}"                               # another key's entry
build corrupt LYRIC_CACHE_DIR="$ccache"
[ "$(count corrupt miss-stored)" = 4 ] || fail "expected exactly the 4 damaged entries re-checked, got $(count corrupt miss-stored)"
[ "$(count corrupt hit)" = "$((stored - 4))" ] || fail "the undamaged entries must still hit"
same_ir corrupt off
build healed LYRIC_CACHE_DIR="$ccache"
[ "$(count healed miss-stored)" = 0 ] || fail "damaged entries were not rewritten"

echo "=== an unwritable cache location costs the speedup, not the build ==="
echo x > "$work/blocker"
build blocked LYRIC_CACHE_DIR="$work/blocker"
same_ir blocked off
echo "native stdlib check cache e2e: OK"
