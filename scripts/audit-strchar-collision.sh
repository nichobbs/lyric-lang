#!/usr/bin/env bash
# audit-strchar-collision.sh — guard rail for #2125.
#
# The F# stage-0 emitter resolves a *qualified* call `Alias.method(...)` by the
# bare method name, ignoring the import alias.  When a compiler source imports
# BOTH `Std.String` (as `Str`) and `Std.Char` (the two modules share the method
# names `fromInt`, `toUpper`, `toLower`), a `Str.fromInt` / `Str.toUpper` /
# `Str.toLower` call silently mis-resolves to `Std.Char.<same>`:
#
#   - `Str.fromInt(n)`  -> `Char.fromInt(n)`  (renders n as a code point, and
#                          panics when n > 65535 — this crashed `urlToHash`,
#                          #2082, and garbled manifest line:col rendering).
#   - `Str.toUpper(s)`  -> `Char.toUpper(s)`  (a `Char -> Char`; a type error).
#
# The self-hosted MSIL emitter resolves these correctly, so the bug only bites
# the compiler sources that stage-0 (F#) compiles into stage1.  Until the
# emitter is fixed (#2125) or retired by self-hosting, those call sites must use
# the unambiguous `toString` builtin (for `fromInt`) or string-only operations.
#
# This script fails if any file under `lyric-compiler/lyric/` imports both
# `Std.String` and `Std.Char` and contains a `Str.{fromInt,toUpper,toLower}`
# call (line comments are ignored).

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
compiler_dir="$root/lyric-compiler/lyric"

if [ ! -d "$compiler_dir" ]; then
  echo "audit-strchar-collision: $compiler_dir not found" >&2
  exit 1
fi

fail=0
while IFS= read -r f; do
  grep -q '^import Std\.Char\b'   "$f" || continue
  grep -q '^import Std\.String\b' "$f" || continue
  # Strip `//` line comments before matching so the explanatory notes that
  # mention `Str.fromInt` do not trip the guard.
  hits="$(sed 's://.*::' "$f" | grep -nE 'Str\.(fromInt|toUpper|toLower)\b' || true)"
  if [ -n "$hits" ]; then
    echo "::error::$f imports both Std.String and Std.Char and uses a colliding Str.* call (#2125):"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
done < <(find "$compiler_dir" -name '*.l' | sort)

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "The F# stage-0 emitter mis-resolves Str.fromInt/toUpper/toLower to"
  echo "Std.Char.<same> in files importing both modules (#2125).  Use the"
  echo "toString builtin (for fromInt) or string-only operations instead."
  exit 1
fi

echo "audit-strchar-collision: clean (no Str.{fromInt,toUpper,toLower} in dual-import compiler sources)"
