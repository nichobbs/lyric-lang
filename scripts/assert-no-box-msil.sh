#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# assert-no-box-msil.sh — measure BOX instructions in MSIL closures
# (epic #1877 Stage 0 baseline / zero-overhead progress gate).
#
# Compiles the closure_zero_overhead_self_test.l module and disassembles
# the resulting MSIL IL to count BOX instructions emitted for primitive
# captures. At Stage 0 the count is expected to be non-zero (baseline);
# Stage 2+ will optimize away most/all primitive-capture boxing.
#
# Usage:
#   scripts/assert-no-box-msil.sh [lyric-bin] [stage]
#
# Arguments:
#   lyric-bin — self-hosted lyric binary (default: ./bin/lyric)
#   stage     — expected stage (default: 0 for baseline; 2+ for pass)
#
# At Stage 0, this script reports the baseline box count and exits 0
# (EXPECT-FAIL in CI — the count will be >0).
#
# At Stage 2+, the script expects box_count == 0 and exits non-zero if
# any BOX instructions are found (REQUIRED-PASS in CI).
#
# Requires: ilasm/ildasm from .NET SDK (usually at:
#   ~/.dotnet/sdk/<version>/bin/ildasm or via dotnet-ildasm tool)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
DOTNET_ROOT="${DOTNET_ROOT:-/usr/share/dotnet}"

LYRIC_BIN="${1:-$REPO_ROOT/bin/lyric}"
STAGE="${2:-0}"

if [[ ! -x "$LYRIC_BIN" ]]; then
  echo "FATAL: lyric binary not found at $LYRIC_BIN" >&2
  echo "  build it first: make lyric" >&2
  exit 2
fi

# Create a temporary workspace for the test compilation.
TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$TMPDIR/assert-no-box-msil.$$"
mkdir -p "$WORK_DIR"
trap "rm -rf '$WORK_DIR'" EXIT

# Create a minimal lyric.toml that imports the closure test module.
cat > "$WORK_DIR/lyric.toml" <<'EOF'
[package]
name = "ClosureZeroOverheadTestMsil"
version = "0.0.1"

[project]
name = "ClosureZeroOverheadTestMsil"

[dependencies]
Std = "*"
EOF

# Copy the closure test module into the work directory.
cp "$REPO_ROOT/lyric-compiler/lyric/closure_zero_overhead_self_test.l" \
   "$WORK_DIR/closure_test.l"

# Compile the test with the self-hosted emitter (--target dotnet).
OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"
echo "[assert-no-box-msil] compiling closure_zero_overhead_self_test.l with --target dotnet"
"$LYRIC_BIN" build --manifest "$WORK_DIR/lyric.toml" --target dotnet -o "$OUT_DIR" \
  || { echo "FATAL: closure test compilation failed" >&2; exit 1; }

# Locate the emitted DLL (should be ClosureZeroOverheadTestMsil.dll).
DLL="$OUT_DIR/ClosureZeroOverheadTestMsil.dll"
[[ -f "$DLL" ]] || { echo "FATAL: compiled DLL not found at $DLL" >&2; exit 1; }

# Find ildasm (the IL disassembler).
# Strategy: try command-v first (direct PATH), then SDK paths, then dotnet-ildasm tool.
ILDASM=""

# Attempt 1: Check PATH
if ILDASM=$(command -v ildasm 2>/dev/null); then
  : # found
elif ILDASM=$(command -v ildasm.exe 2>/dev/null); then
  : # found (Windows)
# Attempt 2: Check .NET SDK directory structure
elif [[ -n "$DOTNET_ROOT" ]] && [[ -d "$DOTNET_ROOT/sdk" ]]; then
  ILDASM=$(find "$DOTNET_ROOT/sdk" -name "ildasm*" -type f 2>/dev/null | head -1)
# Attempt 3: Try dotnet-ildasm tool
elif ILDASM=$(command -v dotnet-ildasm 2>/dev/null); then
  : # found
fi

if [[ -z "$ILDASM" ]]; then
  echo "ERROR: ildasm not found" >&2
  echo "  DOTNET_ROOT=$DOTNET_ROOT" >&2
  echo "  install (Linux/macOS): dotnet tool install -g dotnet-ildasm" >&2
  echo "  install (Windows): .NET SDK includes ildasm.exe in <DOTNET_ROOT>/sdk/<version>/bin/" >&2
  echo "[assert-no-box-msil] SKIP: cannot disassemble (ildasm not available)"
  exit 77  # skip code
fi

# Disassemble the DLL and count BOX instructions.
IL_FILE="$WORK_DIR/closure_test.il"
echo "[assert-no-box-msil] disassembling $DLL via ildasm"
"$ILDASM" "$DLL" -out:"$IL_FILE" >/dev/null 2>&1 || {
  echo "WARNING: ildasm exited non-zero (expected for some versions)" >&2
}

if [[ ! -f "$IL_FILE" ]]; then
  echo "ERROR: ildasm did not produce IL output at $IL_FILE" >&2
  exit 1
fi

# Count BOX instructions in the IL output.
# BOX appears in lines like: "box   [Std.Core]Std.Int"
BOX_COUNT="$(grep -c "^  *box  " "$IL_FILE" || true)"

echo ""
echo "[assert-no-box-msil] ==== BOX instruction count (Stage $STAGE) ===="
echo "[assert-no-box-msil] DLL                    : $DLL"
echo "[assert-no-box-msil] BOX instructions found : $BOX_COUNT"

# Stage 0 (baseline): report the count and pass.
# Stage 2+ (zero-overhead target): fail if count > 0.
if [[ "$STAGE" -eq 0 ]]; then
  echo "[assert-no-box-msil] OK: Stage 0 baseline established (box count = $BOX_COUNT)"
  echo "[assert-no-box-msil] This will be the target to beat in Stage 2+"
  exit 0
elif [[ "$STAGE" -ge 2 ]]; then
  if [[ "$BOX_COUNT" -eq 0 ]]; then
    echo "[assert-no-box-msil] PASS: Stage $STAGE zero-overhead target met (0 BOX instructions)"
    exit 0
  else
    echo "[assert-no-box-msil] FAIL: Stage $STAGE expected 0 BOX instructions, found $BOX_COUNT" >&2
    echo "[assert-no-box-msil] IL snippet (first 10 BOX lines):" >&2
    grep "^  *box  " "$IL_FILE" | head -10 | sed 's/^/  /' >&2
    exit 1
  fi
else
  echo "[assert-no-box-msil] OK: Stage 1 (intermediate); box count = $BOX_COUNT (no gate)"
  exit 0
fi
