#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# small-stack-compile.sh - the compiler must not depend on a large main-thread
# stack.
#
# The compiler recurses over the syntax tree, one frame group per nesting level
# of the user's expressions.  Windows gives a process's main thread 1 MB, and
# Linux 8 MB, so a program with a long `a + b + c + ...` chain (a generated
# source string, say) overflowed on Windows only (#8667 follow-up: the
# `llvm_tls_self_test.l` chain is 160 terms deep) while the Linux jobs passed.
# `lyric` therefore runs on a thread with a stack sized for the compiler
# (bootstrap/src/Lyric.Cli.Aot/Program.cs).
#
# This script keeps that true without Windows: it limits the main-thread stack
# to 1 MB (`ulimit -s 1024`, the Windows default) and compiles and runs
# programs whose expression trees are far deeper than any hand-written source,
# once with a concatenation chain and once with parenthesised nesting.
#
# Usage: LYRIC_BIN=path/to/lyric bash scripts/ci/small-stack-compile.sh
#        (LYRIC_BIN defaults to ./bin/lyric)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bin/lyric}"
stack_kb="${SMALL_STACK_KB:-1024}"
depth="${SMALL_STACK_DEPTH:-400}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A left-associative chain of `depth` string concatenations.
{
  echo "package DeepChain"
  echo "import Std.Console as Console"
  echo "func main(): Int {"
  echo "  val s = \"t0\" +"
  for ((i = 1; i < depth - 1; i++)); do
    echo "    \"t$i\" +"
  done
  echo "    \"t$((depth - 1))\""
  echo "  Console.println(toString(s.length))"
  echo "  0"
  echo "}"
} > "$work/deep_chain.l"

# `depth` nested parenthesised additions.
{
  echo "package DeepParens"
  echo "import Std.Console as Console"
  echo "func main(): Int {"
  printf '  val n = '
  for ((i = 0; i < depth; i++)); do printf '(1 + '; done
  printf '0'
  for ((i = 0; i < depth; i++)); do printf ')'; done
  echo
  echo "  Console.println(toString(n))"
  echo "  0"
  echo "}"
} > "$work/deep_parens.l"

# Characters of `"t0" + "t1" + ...`: the literals are `t` plus the index.
expected_chain="$(awk -v n="$depth" 'BEGIN { t = 0; for (i = 0; i < n; i++) t += 1 + length(i ""); print t }')"

check() {
  local file="$1" want="$2" got
  echo "--- $(basename "$file") under ulimit -s $stack_kb"
  got="$(ulimit -s "$stack_kb"; "$lyric_bin" run "$file" | tail -n 1 | tr -d '\r\n')"
  if [ "$got" != "$want" ]; then
    echo "::error::$(basename "$file"): printed '$got', expected '$want'"
    exit 1
  fi
}

check "$work/deep_chain.l" "$expected_chain"
check "$work/deep_parens.l" "$depth"
echo "OK: depth-$depth expressions compile and run with a ${stack_kb} KB main-thread stack."
