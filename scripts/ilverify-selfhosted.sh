#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ilverify-selfhosted.sh — verify the IL emitted by the SELF-HOSTED MSIL
# emitter is valid (no StackUnexpected / invalid-IL).
#
# The mint (F#) build emits valid IL, so its DLLs pass trivially and tell us
# nothing.  This gate instead emits the whole `Lyric.Cli` compiler closure with
# the SELF-HOSTED emitter (the AOT binary routes `--target dotnet` through
# `Msil.Bridge`) and runs `ilverify` over every emitted DLL.  This is the guard
# the emitter has lacked: self-hosted-emitter IL bugs (e.g. union match-arm type
# tracking) are invisible to the F# build and only surface in the download-seed
# AOT release path as `ilc CodeGenerationFailedException` / runtime
# `InvalidProgramException`.  See #3943.
#
# Usage:
#   scripts/ilverify-selfhosted.sh [lyric-bin]
#
# Requires: a stage-1 bundle (.bootstrap/stage1) and the AOT entry-point built
# against it (or pass an explicit self-hosted `lyric` binary as $1).  Installs
# `dotnet-ilverify` as a global tool if absent.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
DOTNET_ROOT="${DOTNET_ROOT:-/usr/share/dotnet}"

LYRIC_BIN="${1:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/$BUILD_CONFIG/net10.0/lyric}"
if [[ ! -x "$LYRIC_BIN" ]]; then
  echo "FATAL: self-hosted lyric binary not found at $LYRIC_BIN" >&2
  echo "  build it first: ./scripts/bootstrap.sh --stage 1 && dotnet build bootstrap/src/Lyric.Cli.Aot -c $BUILD_CONFIG" >&2
  exit 2
fi

# Ensure ilverify is available.
ILVERIFY="$(command -v ilverify || true)"
if [[ -z "$ILVERIFY" ]]; then
  export PATH="$PATH:$HOME/.dotnet/tools"
  ILVERIFY="$(command -v ilverify || true)"
fi
if [[ -z "$ILVERIFY" ]]; then
  echo "[ilverify] installing dotnet-ilverify global tool"
  dotnet tool install -g dotnet-ilverify >/dev/null 2>&1 || true
  export PATH="$PATH:$HOME/.dotnet/tools"
  ILVERIFY="$(command -v ilverify || true)"
fi
[[ -n "$ILVERIFY" ]] || { echo "FATAL: ilverify not available" >&2; exit 2; }

# 1. Emit the self-hosted compiler closure (per-package DLLs) with the
#    self-hosted emitter.  Mirrors the stage-2 / reproducibility driver.
OUT="$BUILD_DIR/ilverify-out"
rm -rf "$OUT"; mkdir -p "$OUT"
DRIVER_DIR="$BUILD_DIR/ilverify-driver"
rm -rf "$DRIVER_DIR"; mkdir -p "$DRIVER_DIR"
cat > "$DRIVER_DIR/driver.l" <<'EOF'
// Auto-generated driver: pull the whole Lyric.Cli compiler closure + its
// stdlib import closure so the self-hosted emitter emits every package DLL.
package Lyric.IlverifyDriver
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

echo "[ilverify] emitting self-hosted closure via $LYRIC_BIN"
"$LYRIC_BIN" --internal-perpackage-build "$DRIVER_DIR/driver.l" "$OUT" --target dotnet \
  || { echo "FATAL: self-hosted closure emit failed" >&2; exit 1; }

emitted="$(ls "$OUT"/Lyric.*.dll 2>/dev/null | wc -l)"
[[ "$emitted" -gt 0 ]] || { echo "FATAL: no Lyric.*.dll emitted into $OUT" >&2; exit 1; }
echo "[ilverify] emitted $emitted Lyric DLL(s)"

# 2. Build the reference set: every emitted DLL + the shared framework.
SYSDIR="$(dirname "$(ls "$DOTNET_ROOT"/shared/Microsoft.NETCore.App/*/System.Runtime.dll 2>/dev/null | sort | tail -1)")"
[[ -d "$SYSDIR" ]] || { echo "FATAL: could not locate Microsoft.NETCore.App shared framework under $DOTNET_ROOT" >&2; exit 2; }

refs=()
for d in "$OUT"/*.dll; do refs+=( -r "$d" ); done
for d in "$SYSDIR"/*.dll; do refs+=( -r "$d" ); done

# 3. Verify each emitted Lyric package DLL.  Collect a per-DLL error count.
total_errors=0
failed_dlls=()
for d in "$OUT"/Lyric.*.dll; do
  name="$(basename "$d")"
  out="$("$ILVERIFY" "$d" "${refs[@]}" 2>&1 || true)"
  # ilverify prints one "[IL]: Error ..." line per finding.  "Missing method"
  # / "Failed to load type" for reflection-only auto-FFI host shims are a
  # separate (known) class; count only IL validity errors here.
  n="$(printf '%s\n' "$out" | grep -c '\[IL\]: Error' || true)"
  if [[ "$n" -gt 0 ]]; then
    echo "::group::$name — $n IL error(s)"
    printf '%s\n' "$out" | grep '\[IL\]: Error' | sed 's/^/  /'
    echo "::endgroup::"
    total_errors=$((total_errors + n))
    failed_dlls+=( "$name:$n" )
  fi
done

echo ""
echo "[ilverify] ==== summary ===="
if [[ "$total_errors" -eq 0 ]]; then
  echo "[ilverify] OK: self-hosted-emitted IL is verifiable ($emitted DLLs, 0 errors)"
  exit 0
fi
echo "[ilverify] FAIL: $total_errors IL error(s) across ${#failed_dlls[@]} DLL(s):" >&2
for fd in "${failed_dlls[@]}"; do echo "  - $fd" >&2; done
echo "[ilverify] These are self-hosted MSIL emitter bugs (see #3943)." >&2
exit 1
