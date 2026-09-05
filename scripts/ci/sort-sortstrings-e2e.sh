#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
if [ ! -f "$(dirname "$lyric_bin")/Lyric.Stdlib.dll" ]; then
  echo "::error::Lyric.Stdlib.dll bundle not staged — slice-4 test cannot run"
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/s4.l" <<'LYR'
package S4
import Std.Sort as Sort
import Std.Console as Console
func main(): Unit {
  val files: List[String] = newList()
  files.add("gamma.l")
  files.add("alpha.l")
  files.add("beta.l")
  val sorted = Sort.sortStrings(files.toArray())
  var acc = ""
  var i = 0
  while i < sorted.length {
    if i > 0 { acc = acc + " " }
    acc = acc + sorted[i]
    i = i + 1
  }
  Console.println(acc)
}
LYR
# Capture stdout and stderr separately so a trailing compiler warning
# printed to stderr does not replace the program output in the comparison.
# `lyric run` also prints its "built <path> in <N>ms" progress line to
# stdout before the program output, so drop those lines explicitly
# (the old `tail -1` was filtering them implicitly).
s4_stderr="$work/s4.err"
if ! out="$("$lyric_bin" run "$work/s4.l" 2>"$s4_stderr")"; then
  echo "::error::lyric run failed for slice-4 test"
  cat "$s4_stderr" >&2
  exit 1
fi
# Drop build-progress lines, then trim newlines to normalise output.
out="$(printf '%s\n' "$out" | grep -v '^built ' | tr -d '\r\n')"
echo "slice-4 program printed: '$out'"
if [ "$out" != "alpha.l beta.l gamma.l" ]; then
  echo "::error::Sort.sortStrings(list.toArray()) returned '$out' (expected 'alpha.l beta.l gamma.l'); #2592 slice-4 regressed"
  cat "$s4_stderr" >&2
  exit 1
fi
echo "Sort.sortStrings(list.toArray()) returns lexicographically sorted result"

