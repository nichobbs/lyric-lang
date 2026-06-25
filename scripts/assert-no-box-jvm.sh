#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# assert-no-box-jvm.sh — measure boxing in JVM closures
# (epic #1877 Stage 0 baseline / zero-overhead progress gate).
#
# Compiles the closure_zero_overhead_self_test.l module to a JVM JAR
# and disassembles the resulting bytecode to count:
#   • Calls to java.lang.Integer.valueOf (Int boxing)
#   • Calls to java.lang.Long.valueOf (Long boxing)
#   • Calls to java.lang.Float.valueOf (Float boxing)
#
# At Stage 0 the count is expected to be non-zero (baseline);
# Stage 2+ will optimize away most/all primitive-capture boxing.
#
# Usage:
#   scripts/assert-no-box-jvm.sh [lyric-bin] [stage]
#
# Arguments:
#   lyric-bin — self-hosted lyric binary (default: ./bin/lyric)
#   stage     — expected stage (default: 0 for baseline; 2+ for pass)
#
# At Stage 0, this script reports the baseline boxing count and exits 0
# (EXPECT-FAIL in CI — the count will be >0).
#
# At Stage 2+, the script expects box_count == 0 and exits non-zero if
# any boxing calls are found (REQUIRED-PASS in CI).
#
# Requires: javap (JDK tools, usually at $JAVA_HOME/bin/javap or via
#   JAVA_HOME environment variable or 'which javap')
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"

LYRIC_BIN="${1:-$REPO_ROOT/bin/lyric}"
STAGE="${2:-0}"

if [[ ! -x "$LYRIC_BIN" ]]; then
  echo "FATAL: lyric binary not found at $LYRIC_BIN" >&2
  echo "  build it first: make lyric" >&2
  exit 2
fi

# Verify Java/JDK is available.
JAVAP="$(command -v javap || true)"
if [[ -z "$JAVAP" ]] && [[ -n "${JAVA_HOME:-}" ]]; then
  JAVAP="$JAVA_HOME/bin/javap"
fi
if [[ ! -x "$JAVAP" ]]; then
  echo "ERROR: javap not found" >&2
  echo "  ensure JAVA_HOME is set or javap is in PATH" >&2
  echo "[assert-no-box-jvm] SKIP: cannot disassemble (javap not available)"
  exit 77  # skip code
fi

# Create a temporary workspace for the test compilation.
TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$TMPDIR/assert-no-box-jvm.$$"
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

# Create a minimal lyric.toml that imports the closure test module.
cat > "$WORK_DIR/lyric.toml" <<'EOF'
[package]
name = "ClosureZeroOverheadTestJvm"
version = "0.0.1"

[project]
name = "ClosureZeroOverheadTestJvm"

[dependencies]
Std = "*"
EOF

# Copy the closure test module into the work directory.
cp "$REPO_ROOT/lyric-compiler/lyric/closure_zero_overhead_self_test.l" \
   "$WORK_DIR/closure_test.l"

# Compile the test with the self-hosted JVM emitter (--target jvm).
OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"
echo "[assert-no-box-jvm] compiling closure_zero_overhead_self_test.l with --target jvm"
"$LYRIC_BIN" build --manifest "$WORK_DIR/lyric.toml" --target jvm -o "$OUT_DIR" \
  || { echo "FATAL: closure test compilation failed" >&2; exit 1; }

# Locate the emitted JAR (should be ClosureZeroOverheadTestJvm.jar).
JAR="$OUT_DIR/ClosureZeroOverheadTestJvm.jar"
[[ -f "$JAR" ]] || { echo "FATAL: compiled JAR not found at $JAR" >&2; exit 1; }

# Extract and disassemble class files from the JAR.
# We look for boxing calls (Integer.valueOf, Long.valueOf, Float.valueOf, etc.)
# in the disassembled bytecode.
EXTRACT_DIR="$WORK_DIR/classes"
mkdir -p "$EXTRACT_DIR"
echo "[assert-no-box-jvm] extracting classes from $JAR"
unzip -q "$JAR" -d "$EXTRACT_DIR" || true

# Count boxing-related method invocations in the class files.
# Lines like:
#   invokestatic  #45   = java/lang/Integer.valueOf:(I)Ljava/lang/Integer;
#   invokestatic  #xx   = java/lang/Long.valueOf:(J)Ljava/lang/Long;
#   invokestatic  #xx   = java/lang/Float.valueOf:(F)Ljava/lang/Float;
#
# We search for these patterns in javap output.
DISASM_FILE="$WORK_DIR/disasm.txt"
echo "[assert-no-box-jvm] disassembling bytecode via javap"
{
  find "$EXTRACT_DIR" -name "*.class" -type f | while read -r classfile; do
    # Extract fully-qualified class name from file path
    # e.g. classes/com/example/ClosureTest.class → com.example.ClosureTest
    classname=$(echo "$classfile" | sed "s|^$EXTRACT_DIR/||" | sed 's/\.class$//' | tr '/' '.')
    "$JAVAP" -c -private "$classname" 2>/dev/null || "$JAVAP" -c -private "$classfile" 2>/dev/null || true
  done
} > "$DISASM_FILE" 2>&1 || true

# Count boxing calls in the disassembled output.
# Look for:
#   java/lang/Integer.valueOf, java/lang/Long.valueOf, java/lang/Float.valueOf,
#   java/lang/Double.valueOf, java/lang/Boolean.valueOf
BOX_COUNT="$(grep -E "(Integer|Long|Float|Double|Boolean)\.valueOf" "$DISASM_FILE" | wc -l || true)"

echo ""
echo "[assert-no-box-jvm] ==== boxing call count (Stage $STAGE) ===="
echo "[assert-no-box-jvm] JAR                     : $JAR"
echo "[assert-no-box-jvm] boxing calls found      : $BOX_COUNT"

# Stage 0 (baseline): report the count and pass.
# Stage 2+ (zero-overhead target): fail if count > 0.
if [[ "$STAGE" -eq 0 ]]; then
  echo "[assert-no-box-jvm] OK: Stage 0 baseline established (boxing count = $BOX_COUNT)"
  echo "[assert-no-box-jvm] This will be the target to beat in Stage 2+"
  exit 0
elif [[ "$STAGE" -ge 2 ]]; then
  if [[ "$BOX_COUNT" -eq 0 ]]; then
    echo "[assert-no-box-jvm] PASS: Stage $STAGE zero-overhead target met (0 boxing calls)"
    exit 0
  else
    echo "[assert-no-box-jvm] FAIL: Stage $STAGE expected 0 boxing calls, found $BOX_COUNT" >&2
    echo "[assert-no-box-jvm] disassembly snippet (first 10 boxing lines):" >&2
    grep -E "(Integer|Long|Float|Double|Boolean)\.valueOf" "$DISASM_FILE" | head -10 | sed 's/^/  /' >&2
    exit 1
  fi
else
  echo "[assert-no-box-jvm] OK: Stage 1 (intermediate); boxing count = $BOX_COUNT (no gate)"
  exit 0
fi
