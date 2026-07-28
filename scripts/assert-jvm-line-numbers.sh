#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# assert-jvm-line-numbers.sh — verify the JVM backend emits a correct
# `LineNumberTable` (JVMS §4.7.12) for every method body.
#
# This is the acceptance oracle for docs/63 band B2. Before B2 the JVM
# backend emitted a `SourceFile` attribute but no line table at all, so a
# Java stack trace from Lyric code read `(Unknown Source)` and no JDWP
# debugger could set a line breakpoint.
#
# The check is exact, not a smoke test: the fixture below declares, per
# method, the precise set of source lines that must appear in that method's
# table. A row pointing at the wrong line is as much a failure as a missing
# table — a debugger that stops on the wrong statement is worse than one
# that cannot stop at all.
#
# Usage:
#   scripts/assert-jvm-line-numbers.sh [lyric-bin]
#
# Arguments:
#   lyric-bin — self-hosted lyric binary (default: ./bin/lyric)
#
# Exit codes:
#   0  — all expectations met
#   1  — a table is missing, or its rows do not match the expectation
#   2  — the lyric binary is missing (cannot run the check)
#  77  — skipped: javap unavailable
#
# Requires: javap (JDK tools), unzip, java 21.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRIC_BIN="${1:-$REPO_ROOT/bin/lyric}"

if [[ ! -x "$LYRIC_BIN" ]]; then
  if [[ -x "${LYRIC_BIN}.exe" ]]; then
    LYRIC_BIN="${LYRIC_BIN}.exe"
  else
    echo "FATAL: lyric binary not found at $LYRIC_BIN" >&2
    echo "  build it first: make lyric" >&2
    exit 2
  fi
fi

JAVAP="$(command -v javap || true)"
if [[ -z "$JAVAP" ]] && [[ -n "${JAVA_HOME:-}" ]]; then
  JAVAP="$JAVA_HOME/bin/javap"
fi
if [[ ! -x "${JAVAP:-}" ]]; then
  echo "[assert-jvm-line-numbers] SKIP: javap not available" >&2
  exit 77
fi

WORK_DIR="$REPO_ROOT/bootstrap/assert-jvm-line-numbers.$$"
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

# ---------------------------------------------------------------------------
# Fixture. Generated here rather than checked in under lyric-compiler/ so the
# source lines and the expectations below cannot drift apart: renumbering the
# program without renumbering EXPECT is a visible edit to a single file.
#
# Line numbers are 1-based, counting the `//!` as line 1:
#
#    1 //! ...                     22 aspect Traced {
#    2                             23   matches: name in { wovenAdd }
#    3 package LyricB2Lines        24   around(call) -> ret {
#    4                             25     ret = proceed()
#    5 func step(n: Int): Int {    26   }
#    6   val a = n + 1             27 }
#    7   val b = a * 2             28
#    8   val c = b - 3             29 func wovenAdd(a: Int, b: Int): Int {
#    9   return c                  30   val s = a + b
#   10 }                           31   return s
#   11                             32 }
#   12 func loopSum(n: Int): Int { 33
#   13   var total = 0             34 func main(): Int {
#   14   var i = 0                 35   val x = step(5)
#   15   while i < n {             36   println("x=" ...)
#   16     total = total + i       37   val y = loopSum(4)
#   17     i = i + 1               38   println("y=" ...)
#   18   }                         39   val z = wovenAdd(20, 22)
#   19   return total              40   println("z=" ...)
#   20 }                           41   return 0
#   21                             42 }
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/lines.l" <<'EOF'
//! Fixture for scripts/assert-jvm-line-numbers.sh (docs/63 band B2).

package LyricB2Lines

func step(n: Int): Int {
  val a = n + 1
  val b = a * 2
  val c = b - 3
  return c
}

func loopSum(n: Int): Int {
  var total = 0
  var i = 0
  while i < n {
    total = total + i
    i = i + 1
  }
  return total
}

aspect Traced {
  matches: name in { wovenAdd }
  around(call) -> ret {
    ret = proceed()
  }
}

func wovenAdd(a: Int, b: Int): Int {
  val s = a + b
  return s
}

func main(): Int {
  val x = step(5)
  println("x=" + x.toString())
  val y = loopSum(4)
  println("y=" + y.toString())
  val z = wovenAdd(20, 22)
  println("z=" + z.toString())
  return 0
}
EOF

# Expected line-number sets. Each is the set of source lines carrying a
# statement in that method body — the emitter emits one marker per statement
# and then collapses rows that repeat a line or share a start_pc (see
# `Jvm.Lowering.lowerFuncImpl`), so the expectation is a SET compared after
# `sort -n -u`. Row count is an emitter detail; the lines covered are not.
#
# `loopSum` pins the loop case: the `while` header (17) and both body
# statements (18, 19) must appear, the closing brace (20) must not, and the
# back edge must not invent rows outside the body.
EXPECT_step="6,7,8,9"
EXPECT_loopSum="13,14,15,16,17,19"

# The weave case, and the regression guard for #6285.
#
# `wovenAdd` in the class file is the weaver's *wrapper*; the original body is
# renamed to `wovenAdd__aspect_target`. The wrapper is built almost entirely
# from synthesized statements (argument binding, the call to the target, return
# plumbing) which correspond to no source text — the one real statement in it is
# the aspect's own `ret = proceed()` on line 25.
#
# Before #6285 the weaver's synthesized spans claimed line 1 rather than "no
# line", so the wrapper also carried spurious `line 1` rows. Pinning this to
# exactly {25} is what makes that regression impossible to reintroduce
# silently.
EXPECT_wovenAdd="25"
EXPECT_wovenAdd__aspect_target="30,31"

# `main` is checked as a subset rather than exactly: the JVM backend also
# emits a synthetic `main(String[])` entry-point bridge, so two methods share
# the name and their rows land in one bucket. Every row must still fall on a
# real statement line of the Lyric `main`, which is what catches a wrong-line
# regression; the bridge contributes no rows of its own.
EXPECT_main_ALLOWED="35,36,37,38,39,40,41"
EXPECT_main_MIN_ROWS=3

cat > "$WORK_DIR/lyric.toml" <<'EOF'
[package]
name = "LyricB2Lines"
version = "0.0.1"

[project]
name = "LyricB2Lines"

[project.packages]
"LyricB2Lines" = "lines.l"

[dependencies]
Std = "*"
EOF

OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"
JAR="$OUT_DIR/LyricB2Lines.jar"

echo "[assert-jvm-line-numbers] compiling fixture with --target jvm"
"$LYRIC_BIN" build --manifest "$WORK_DIR/lyric.toml" --target jvm -o "$JAR" \
  || { echo "FATAL: fixture compilation failed" >&2; exit 1; }
[[ -f "$JAR" ]] || { echo "FATAL: compiled JAR not found at $JAR" >&2; exit 1; }

# The program must still run. A malformed Code attribute (wrong sub-attribute
# count, bad start_pc) is rejected by the verifier at class load, so a clean
# run is a real check that the new attribute did not corrupt the method body.
echo "[assert-jvm-line-numbers] running the fixture"
RUN_OUT="$WORK_DIR/run.txt"
if ! java -jar "$JAR" > "$RUN_OUT" 2>&1; then
  echo "FAIL: fixture did not run after adding LineNumberTable" >&2
  sed 's/^/  /' "$RUN_OUT" >&2
  exit 1
fi
# step(5) = ((5+1)*2)-3 = 9 ; loopSum(4) = 0+1+2+3 = 6 ; wovenAdd(20,22) = 42
# (the last one also proves the woven wrapper still returns the target's value)
if ! grep -qx "x=9" "$RUN_OUT" || ! grep -qx "y=6" "$RUN_OUT" || ! grep -qx "z=42" "$RUN_OUT"; then
  echo "FAIL: fixture produced wrong output (expected x=9, y=6, z=42)" >&2
  sed 's/^/  /' "$RUN_OUT" >&2
  exit 1
fi
echo "[assert-jvm-line-numbers] OK  runtime output (x=9, y=6, z=42)"

EXTRACT_DIR="$WORK_DIR/classes"
mkdir -p "$EXTRACT_DIR"
unzip -q "$JAR" -d "$EXTRACT_DIR" || true

# Disassemble only the fixture's own classes. The bundled JVM compile packs
# the transitive stdlib closure into the same JAR; stdlib line tables are not
# what this check calibrates.
DISASM="$WORK_DIR/disasm.txt"
: > "$DISASM"
while read -r classfile; do
  "$JAVAP" -l -p "$classfile" 2>/dev/null >> "$DISASM" || true
done < <(find "$EXTRACT_DIR" -path "*LyricB2Lines*" -name "*.class" -type f)

if [[ ! -s "$DISASM" ]]; then
  echo "FAIL: javap produced no output for the fixture classes" >&2
  find "$EXTRACT_DIR" -name "*.class" -type f | head -20 >&2
  exit 1
fi

# Collect the LineNumberTable line numbers belonging to one method.
#
# `javap -l -p` prints, per method:
#     public static int step(int);
#       Code:
#         LineNumberTable:
#           line 8: 0
#           line 9: 4
# Method signature lines are the only ones indented by exactly two spaces and
# starting with a letter, which is what delimits the regions.
#
# The name match is anchored on both sides. A plain substring search for
# `m "("` would fold a method into the wrong bucket whenever one name is a
# suffix of another — looking for `main` would also match `domain(`, since
# "domain(" contains "main(". An oracle that claims to be exact cannot silently
# merge two methods' rows, so require a non-identifier character (or line start)
# immediately before the name.
lines_for_method() {
  local method="$1"
  awk -v m="$method" '
    /^  [A-Za-z_$][^;]*\(.*\);[ ]*$/ {
      inm = ($0 ~ ("(^|[^A-Za-z0-9_$])" m "\\("))
      next
    }
    inm && /^ *line [0-9]+: [0-9]+$/ {
      sub(/^ *line /, ""); sub(/:.*$/, ""); print
    }
  ' "$DISASM" | sort -n -u | paste -sd, -
}

fail=0

check_method_exact() {
  local method="$1" expect="$2"
  local got want
  got="$(lines_for_method "$method")"
  want="$(printf '%s' "$expect" | tr ',' '\n' | sort -n -u | paste -sd, -)"
  if [[ -z "$got" ]]; then
    echo "FAIL: $method — no LineNumberTable rows found (expected lines: $want)" >&2
    fail=1
    return
  fi
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $method — LineNumberTable lines mismatch" >&2
    echo "        expected: $want" >&2
    echo "        actual  : $got" >&2
    fail=1
    return
  fi
  echo "[assert-jvm-line-numbers] OK  $method -> $got"
}

check_method_subset() {
  local method="$1" allowed="$2" minrows="$3"
  local got count
  got="$(lines_for_method "$method")"
  if [[ -z "$got" ]]; then
    echo "FAIL: $method — no LineNumberTable rows found (allowed lines: $allowed)" >&2
    fail=1
    return
  fi
  count=0
  local ln
  for ln in ${got//,/ }; do
    count=$((count + 1))
    if [[ ",$allowed," != *",$ln,"* ]]; then
      echo "FAIL: $method — row on line $ln is outside the method's statements ($allowed)" >&2
      fail=1
    fi
  done
  if [[ "$count" -lt "$minrows" ]]; then
    echo "FAIL: $method — only $count distinct lines, expected at least $minrows" >&2
    fail=1
    return
  fi
  [[ "$fail" -eq 0 ]] && echo "[assert-jvm-line-numbers] OK  $method -> $got"
}

check_method_exact step "$EXPECT_step"
check_method_exact loopSum "$EXPECT_loopSum"
check_method_exact wovenAdd "$EXPECT_wovenAdd"
check_method_exact wovenAdd__aspect_target "$EXPECT_wovenAdd__aspect_target"
check_method_subset main "$EXPECT_main_ALLOWED" "$EXPECT_main_MIN_ROWS"

# Belt-and-braces guard for #6285, independent of the per-method expectations
# above: line 1 of the fixture is a `//!` comment, so no statement can live
# there and no row may name it. A synthesized span leaking a real-looking
# position tends to surface as exactly this, in whatever method happens to be
# woven or elaborated.
if grep -qE "^ *line 1: [0-9]+$" "$DISASM"; then
  echo "FAIL: a row names line 1, which holds only a comment — a synthesized" >&2
  echo "      span is being treated as a real source position (#6285)" >&2
  grep -nE "^ *line 1: [0-9]+$" "$DISASM" | head -5 >&2
  fail=1
else
  echo "[assert-jvm-line-numbers] OK  no rows on the comment-only line 1"
fi

# Known gap, tracked as the first slice of docs/63 band B1: no `SourceFile`
# attribute is emitted, because `Jvm.Codegen.codegenPackage` receives a
# `SourceFile` AST node and that record carries no path — the real path is
# dropped in `cli_build.l` before the backend ever sees it. `classfile.l` has
# a `makeSourceFileAttr` builder, but nothing calls it.
#
# Consequence: a line number resolves to no file, so `Throwable.printStackTrace`
# still prints `(Unknown Source)` even though JDWP line breakpoints work off
# the tables asserted above.
#
# This is asserted as a *pending* state rather than ignored: when B1 threads
# the path through and SourceFile starts being emitted, this check fires and
# forces the expectation above to be tightened instead of silently going stale.
if grep -q 'SourceFile:' "$DISASM"; then
  echo "NOTE: a SourceFile attribute is now emitted — band B1 has landed." >&2
  echo "      Replace this block with a real assertion on the file name." >&2
  fail=1
else
  echo "[assert-jvm-line-numbers] PENDING  SourceFile not emitted yet (band B1)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "[assert-jvm-line-numbers] FAIL — line-table disassembly follows:" >&2
  grep -nE "^  [A-Za-z_$][^;]*\(|LineNumberTable|^ *line [0-9]+:" "$DISASM" | head -80 >&2
  exit 1
fi

echo "[assert-jvm-line-numbers] PASS — all methods carry correct line tables"
