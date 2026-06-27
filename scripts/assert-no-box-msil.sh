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
export PATH="$HOME/.dotnet/tools:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
DOTNET_ROOT="${DOTNET_ROOT:-/usr/share/dotnet}"

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

# Create a temporary workspace for the test compilation.
WORK_DIR="$REPO_ROOT/bootstrap/assert-no-box-msil.$$"
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

# Compile the test with the self-hosted emitter (--target dotnet).
OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"
DLL="$OUT_DIR/Lyric.ClosureZeroOverheadSelfTest.dll"

echo "[assert-no-box-msil] compiling closure_zero_overhead_self_test.l with --target dotnet"
"$LYRIC_BIN" build --manifest "$WORK_DIR/lyric.toml" --target dotnet -o "$DLL" \
  || { echo "FATAL: closure test compilation failed" >&2; exit 1; }

[[ -f "$DLL" ]] || { echo "FATAL: compiled DLL not found at $DLL" >&2; exit 1; }

# Find ildasm (the IL disassembler).
# Strategy: try command-v first (direct PATH), then SDK paths, then dotnet-ildasm tool,
# then try to install dotnet-ildasm if dotnet is available.
ILDASM=""

# Attempt 1: Check PATH
if [[ -z "$ILDASM" ]]; then
  if command -v ildasm >/dev/null 2>&1; then
    ILDASM="ildasm"
  elif command -v ildasm.exe >/dev/null 2>&1; then
    ILDASM="ildasm.exe"
  fi
fi

# Attempt 2: Check .NET SDK directory structure
if [[ -z "$ILDASM" ]] && [[ -n "$DOTNET_ROOT" ]] && [[ -d "$DOTNET_ROOT/sdk" ]]; then
  ILDASM_PATH=$(find "$DOTNET_ROOT/sdk" -name "ildasm*" -type f 2>/dev/null | head -1 || true)
  if [[ -n "$ILDASM_PATH" ]]; then
    ILDASM="$ILDASM_PATH"
  fi
fi

# Attempt 3: Try dotnet-ildasm tool
if [[ -z "$ILDASM" ]]; then
  if command -v dotnet-ildasm >/dev/null 2>&1; then
    ILDASM="dotnet-ildasm"
  elif [[ -x "$REPO_ROOT/.tools/dotnet-ildasm" ]]; then
    ILDASM="$REPO_ROOT/.tools/dotnet-ildasm"
  elif [[ -x "./.tools/dotnet-ildasm" ]]; then
    ILDASM="./.tools/dotnet-ildasm"
  elif [[ -x "/home/runner/.dotnet/tools/dotnet-ildasm" ]]; then
    ILDASM="/home/runner/.dotnet/tools/dotnet-ildasm"
  elif [[ -x "$HOME/.dotnet/tools/dotnet-ildasm" ]]; then
    ILDASM="$HOME/.dotnet/tools/dotnet-ildasm"
  fi
fi

# Attempt 4: Try 'dotnet ildasm' command (newer .NET SDK versions)
if [[ -z "$ILDASM" ]] && command -v dotnet >/dev/null 2>&1 && dotnet ildasm --help >/dev/null 2>&1; then
  ILDASM="dotnet ildasm"
fi

# Attempt 5: Try on-the-fly local installation
if [[ -z "$ILDASM" ]] && command -v dotnet >/dev/null 2>&1; then
  echo "Installing dotnet-ildasm to local tool directory..."
  if dotnet tool install --tool-path "$WORK_DIR/tools" dotnet-ildasm >/dev/null 2>&1; then
    ILDASM="$WORK_DIR/tools/dotnet-ildasm"
  fi
fi

if [[ -z "$ILDASM" ]]; then
  echo "ERROR: ildasm not found" >&2
  echo "  DOTNET_ROOT=$DOTNET_ROOT" >&2
  echo "  install (Linux/macOS): dotnet tool install -g dotnet-ildasm" >&2
  echo "  install (Windows): .NET SDK includes ildasm.exe in <DOTNET_ROOT>/sdk/<version>/bin/" >&2

  # At Stage 0 (baseline), we can skip the test if ildasm is unavailable.
  # At Stage 2+ (gates), we must error because the test is required to verify zero-overhead.
  if [[ "$STAGE" -eq 0 ]]; then
    echo "[assert-no-box-msil] SKIP: cannot disassemble (ildasm not available); skipping Stage 0 baseline"
    exit 77  # skip code
  else
    echo "[assert-no-box-msil] FAIL: cannot disassemble (ildasm not available); required for Stage $STAGE gate" >&2
    exit 1
  fi
fi

# Disassemble the DLL and count BOX instructions.
IL_FILE="$WORK_DIR/closure_test.il"
echo "[assert-no-box-msil] disassembling $DLL via ildasm"
# Handle both single commands (ildasm) and multi-word commands (dotnet ildasm)
if [[ "$ILDASM" == *"dotnet-ildasm"* ]] || [[ "$ILDASM" == *"dotnet ildasm"* ]]; then
  DOTNET_ROLL_FORWARD=LatestMajor $ILDASM "$DLL" -o "$IL_FILE" >/dev/null 2>&1 || {
    echo "WARNING: ildasm exited non-zero (expected for some versions)" >&2
  }
else
  "$ILDASM" "$DLL" -out:"$IL_FILE" >/dev/null 2>&1 || {
    echo "WARNING: ildasm exited non-zero (expected for some versions)" >&2
  }
fi

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
