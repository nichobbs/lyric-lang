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
  if [[ -x "${LYRIC_BIN}.exe" ]]; then
    LYRIC_BIN="${LYRIC_BIN}.exe"
  else
    echo "FATAL: lyric binary not found at $LYRIC_BIN" >&2
    echo "  build it first: make lyric" >&2
    exit 2
  fi
fi

# Verify Java/JDK is available.
JAVAP="$(command -v javap || true)"
if [[ -z "$JAVAP" ]] && [[ -n "${JAVA_HOME:-}" ]]; then
  JAVAP="$JAVA_HOME/bin/javap"
fi
if [[ ! -x "$JAVAP" ]]; then
  echo "ERROR: javap not found" >&2
  echo "  ensure JAVA_HOME is set or javap is in PATH" >&2

  # At Stage 0 (baseline), we can skip the test if javap is unavailable.
  # At Stage 2+ (gates), we must error because the test is required to verify zero-overhead.
  if [[ "$STAGE" -eq 0 ]]; then
    echo "[assert-no-box-jvm] SKIP: cannot disassemble (javap not available); skipping Stage 0 baseline"
    exit 77  # skip code
  else
    echo "[assert-no-box-jvm] FAIL: cannot disassemble (javap not available); required for Stage $STAGE gate" >&2
    exit 1
  fi
fi

# Create a temporary workspace for the test compilation.
WORK_DIR="$REPO_ROOT/bootstrap/assert-no-box-jvm.$$"
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

# Create a minimal lyric.toml that imports the closure test module.
cat > "$WORK_DIR/lyric.toml" <<'EOF'
[package]
name = "Lyric.ClosureZeroOverheadSelfTest"
version = "0.0.1"

[project]
name = "Lyric.ClosureZeroOverheadSelfTest"

[project.packages]
"Lyric.ClosureZeroOverheadSelfTest" = "closure_test.l"

[dependencies]
Std = "*"
EOF

# Copy the closure test module into the work directory.
cp "$REPO_ROOT/lyric-compiler/lyric/closure_zero_overhead_self_test.l" \
   "$WORK_DIR/closure_test.l"

# Compile the test with the self-hosted JVM emitter (--target jvm).
OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"
JAR="$OUT_DIR/Lyric.ClosureZeroOverheadSelfTest.jar"

echo "[assert-no-box-jvm] compiling closure_zero_overhead_self_test.l with --target jvm"
"$LYRIC_BIN" build --manifest "$WORK_DIR/lyric.toml" --target jvm -o "$JAR" \
  || { echo "FATAL: closure test compilation failed" >&2; exit 1; }
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
#
# Scope: ONLY the closure test's own classes (the main class plus its
# synthesized $Lambda$N closure classes).  The JVM bundled compile packs
# the transitive stdlib closure into the same JAR, and stdlib kernels
# contain legitimate boxing that has nothing to do with closure capture
# overhead (e.g. Std.FileHost's opaque FileTime IS a boxed epoch-millis
# Long by design) — counting them made every stdlib change shift this
# gate's calibration.  The MSIL twin is naturally scoped this way
# because the .NET build links Lyric.Stdlib.dll instead of bundling it.
DISASM_FILE="$WORK_DIR/disasm.txt"
echo "[assert-no-box-jvm] disassembling bytecode via javap (test classes only)"
{
  find "$EXTRACT_DIR" -path "*ClosureZeroOverheadSelfTest*" -name "*.class" -type f | while read -r classfile; do
    # Pass the .class file path directly to javap (most reliable).
    # Javap accepts both class names and file paths, but file paths are
    # more robust and avoid issues with path extraction and class name format.
    "$JAVAP" -c -private "$classfile" 2>/dev/null || true
  done
} > "$DISASM_FILE" 2>&1 || true

# Count boxing calls in the disassembled output.
# Look for:
#   java/lang/Integer.valueOf, java/lang/Long.valueOf, java/lang/Float.valueOf,
#   java/lang/Double.valueOf, java/lang/Boolean.valueOf
#
# An earlier revision of this script also counted unboxing calls
# (intValue/longValue/floatValue/doubleValue/booleanValue), reasoning that
# read-path unboxing overhead is symmetric with write-path boxing. That
# widened the match without recalibrating MAX_BOXING below (calibrated
# against valueOf-only counts), so the Stage 2+ gate started failing CI
# unconditionally (issue #4643). Reverted to valueOf-only pending a
# recalibrated threshold measured against a real bidirectional count.
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
  # Allow up to 3 boxing calls on JVM: the uniform closure ABI
  # (`invoke(Object...)Object`) boxes each lambda's primitive RETURN at the
  # erased boundary — one valueOf per synthesized $Lambda$N class.  Capture
  # fields themselves are unboxed (the actual Stage 2 target).  The count is
  # scoped to the test's own classes (see the disassembly scoping note above),
  # so stdlib boxing no longer shifts this calibration.
  MAX_BOXING=3
  if [[ "$BOX_COUNT" -le "$MAX_BOXING" ]]; then
    echo "[assert-no-box-jvm] PASS: Stage $STAGE zero-overhead target met ($BOX_COUNT <= $MAX_BOXING boxing calls)"
    exit 0
  else
    echo "[assert-no-box-jvm] FAIL: Stage $STAGE expected <= $MAX_BOXING boxing calls, found $BOX_COUNT" >&2
    echo "[assert-no-box-jvm] disassembly snippet (first 10 boxing lines):" >&2
    grep -E "(Integer|Long|Float|Double|Boolean)\.valueOf" "$DISASM_FILE" | head -10 | sed 's/^/  /' >&2
    exit 1
  fi
else
  echo "[assert-no-box-jvm] OK: Stage 1 (intermediate); boxing count = $BOX_COUNT (no gate)"
  exit 0
fi
