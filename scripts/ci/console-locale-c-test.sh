#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# console-locale-c-test.sh — run
# lyric-stdlib/tests/console_locale_c_tests.l under `LC_ALL=C LANG=C` (a
# C/POSIX locale, common in containers/CI) and byte-diff its raw stdout and
# stderr against the exact expected UTF-8 bytes with `cmp` (#7513).
#
# On `--target jvm` this is the load-bearing run: before
# `Jvm.Codegen.emitConsoleUtf8Setup` (#7513), `System.out`/`System.err`
# encoded through the JVM's platform-default charset, which under `LC_ALL=C`
# is ASCII, turning every non-ASCII `println`/`print`/`Std.Console.error`
# byte into `?`; `System.in` decoded the same way, mangling non-ASCII
# `readLine()` input. Deliberately does NOT rely on `-Dfile.encoding` /
# `-Dstdout.encoding` JVM flags — the fix must hold with none set (the
# sandbox's own `JAVA_TOOL_OPTIONS` is for proxy config only and carries
# neither). `--target dotnet` is covered too, as a same-script parity check
# (.NET's console writers are UTF-8 regardless of locale, so it should pass
# unconditionally).
#
# Usage: console-locale-c-test.sh <lyric-binary> [--target jvm|--target native]
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: console-locale-c-test.sh <lyric-binary> [--target jvm|--target native]}"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stdin_line="stdin café 😀 中文"
printf '%s\n' "$stdin_line" \
  | LC_ALL=C LANG=C "$LYRIC_BIN" run "$@" lyric-stdlib/tests/console_locale_c_tests.l \
      > "$work/raw_stdout" 2> "$work/raw_stderr"

# `lyric run` prints its own "built <path> in <N>ms" progress line to stdout
# ahead of the program's own output (cli_build.l's `Console.println`); strip
# that one line before comparing the program's raw bytes, same as
# console-stdout-bytes-test.sh. A `java` launcher may also emit its own
# "Picked up JAVA_TOOL_OPTIONS: ..." advisory line to stderr when that env
# var is set (a sandbox/proxy-config artifact, not program output); strip it
# too so the comparison stays specific to this program's own stderr bytes.
sed '/^built /d' "$work/raw_stdout" > "$work/actual_stdout"
sed '/^Picked up JAVA_TOOL_OPTIONS/d' "$work/raw_stderr" > "$work/actual_stderr"

python3 -c '
import sys
line = sys.argv[1]
out = "café 😀 中文\n" + "café 😀 中文" + "\n" + "echo:" + line + "\n"
sys.stdout.buffer.write(out.encode("utf-8"))
' "$stdin_line" > "$work/expected_stdout"
python3 -c 'import sys; sys.stdout.buffer.write("erré 😀\n".encode("utf-8"))' > "$work/expected_stderr"

fail=0
if ! cmp -s "$work/actual_stdout" "$work/expected_stdout"; then
  echo "console-locale-c-test: FAILED — raw stdout bytes did not match under LC_ALL=C" >&2
  echo "expected:" >&2
  od -An -tx1z "$work/expected_stdout" >&2
  echo "actual:" >&2
  od -An -tx1z "$work/actual_stdout" >&2
  fail=1
fi
if ! cmp -s "$work/actual_stderr" "$work/expected_stderr"; then
  echo "console-locale-c-test: FAILED — raw stderr bytes did not match under LC_ALL=C" >&2
  echo "expected:" >&2
  od -An -tx1z "$work/expected_stderr" >&2
  echo "actual:" >&2
  od -An -tx1z "$work/actual_stderr" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "console-locale-c-test: ok ($LYRIC_BIN run $* ... under LC_ALL=C)"
