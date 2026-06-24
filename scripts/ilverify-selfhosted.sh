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
#    self-hosted emitter — TWICE, so the closure is ARITY-CONSISTENT.
#
# Why two passes:  the self-hosted emitter stamps the CLR arity suffix on
# generic TypeDefs (`Std.Core.Option`1`), but its cross-assembly *TypeRef*
# path matches whatever `Lyric.Stdlib.Core.dll` it detects on disk
# (`Mdr.detectStdlibCoreDllUsesAritySuffix`): the F# bootstrap stdlib omits
# the suffix (`Std.Core.Option`), the self-hosted stdlib carries it.  In a
# MINT build the on-disk Core beside the binary is the F#-emitted one, so a
# single-pass emit produces consumers that reference `Std.Core.Option` (no
# suffix) while the freshly-emitted stdlib defines `Std.Core.Option`1` — an
# *internal* mismatch that makes ilverify report ~1300 spurious
# `[ClassLoadGeneral] Failed to load type 'Std.Core.Option'` errors that say
# nothing about the emitter's IL validity (#3943).
#
# To "check what's actually going on" we must verify a set where the emitter,
# the compiler/CLI, and the stdlib are all self-hosted *and consistent*.  So:
#   pass 1 → $OUT      : produces a self-hosted (arity-suffixed) stdlib.
#   pass 2 → $OUT2     : re-emit with LYRIC_STDLIB_BIN=$OUT so the consumer
#                        TypeRefs detect the arity stdlib and match it.
# We verify $OUT2 against $OUT2's own DLLs: arity refs ↔ arity defs.
OUT="$BUILD_DIR/ilverify-out"
OUT2="$BUILD_DIR/ilverify-out2"
rm -rf "$OUT" "$OUT2"; mkdir -p "$OUT" "$OUT2"
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

echo "[ilverify] pass 1: emitting self-hosted closure via $LYRIC_BIN"
"$LYRIC_BIN" --internal-perpackage-build "$DRIVER_DIR/driver.l" "$OUT" --target dotnet \
  || { echo "FATAL: self-hosted closure emit (pass 1) failed" >&2; exit 1; }
[[ -f "$OUT/Lyric.Stdlib.Core.dll" ]] \
  || { echo "FATAL: pass 1 did not emit Lyric.Stdlib.Core.dll into $OUT" >&2; exit 1; }

echo "[ilverify] pass 2: re-emitting against the self-hosted (arity) stdlib in $OUT"
LYRIC_STDLIB_BIN="$OUT" "$LYRIC_BIN" --internal-perpackage-build "$DRIVER_DIR/driver.l" "$OUT2" --target dotnet \
  || { echo "FATAL: self-hosted closure emit (pass 2) failed" >&2; exit 1; }

emitted="$(ls "$OUT2"/Lyric.*.dll 2>/dev/null | wc -l)"
[[ "$emitted" -gt 0 ]] || { echo "FATAL: no Lyric.*.dll emitted into $OUT2" >&2; exit 1; }
echo "[ilverify] emitted $emitted Lyric DLL(s) (arity-consistent closure)"

# 2. Build the reference set: every emitted DLL + the shared framework +
#    the self-hosted Lyric.Stdlib.dll bundle.
#
# WHY Lyric.Stdlib.dll is required:
#   `stdlibAssemblyName()` (codegen.l) maps every `Std.*` type (except the
#   Http/async surface) to AssemblyRef `"Lyric.Stdlib"` — the single bundle
#   identity mandated by D111.  `--internal-perpackage-build` only emits
#   per-package DLLs (`Lyric.Stdlib.Core.dll`, …), not the bundle, so without
#   this line every compiler-package method whose signature references a stdlib
#   type produces `[FileLoadErrorGeneric] Failed to load assembly 'Lyric.Stdlib'`
#   — masking all real IL-validity signal with ~1500 spurious errors.
#
# `stage-selfhosted-stdlib.sh` (run by the build job) already built a
# self-hosted, arity-consistent `Lyric.Stdlib.dll` and deployed it beside the
# AOT binary, so we just need to include it here.  The per-package HTTP/async
# DLLs beside it cover the `Lyric.Stdlib.Http` etc. references.
SYSDIR="$(dirname "$(ls "$DOTNET_ROOT"/shared/Microsoft.NETCore.App/*/System.Runtime.dll 2>/dev/null | sort | tail -1)")"
[[ -d "$SYSDIR" ]] || { echo "FATAL: could not locate Microsoft.NETCore.App shared framework under $DOTNET_ROOT" >&2; exit 2; }

LYRIC_DIR="$(dirname "$LYRIC_BIN")"

refs=()
for d in "$OUT2"/*.dll; do refs+=( -r "$d" ); done
# Include the self-hosted Lyric.Stdlib.dll bundle (and per-package HTTP DLLs)
# from the AOT binary's lib dir so `Lyric.Stdlib` assembly references resolve.
if [[ -f "$LYRIC_DIR/Lyric.Stdlib.dll" ]]; then
  refs+=( -r "$LYRIC_DIR/Lyric.Stdlib.dll" )
else
  echo "[ilverify] WARNING: Lyric.Stdlib.dll not found beside the AOT binary — FileLoadErrorGeneric errors expected" >&2
fi
for d in "$LYRIC_DIR"/Lyric.Stdlib.*.dll; do
  [[ -f "$d" ]] && refs+=( -r "$d" )
done
for d in "$SYSDIR"/*.dll; do refs+=( -r "$d" ); done

# 3. Verify each emitted Lyric package DLL.  Bucket findings:
#    * IL-validity   — StackUnexpected / StackUnderflow / PathStackDepth / …:
#                      genuine self-hosted MSIL emitter bugs.  GATE-BLOCKING.
#    * resolution    — ClassLoadGeneral / MissingMethod / FileLoadErrorGeneric:
#                      ilverify could not load a referenced type, method, or
#                      assembly.  Dominated by extern-FFI host shims whose BCL
#                      targets ilverify cannot resolve reflection-only
#                      (`System.Text.Json.JsonElement` nested enumerators,
#                      `Dictionary`.KeyCollection, `Task`1`, …).
#                      INFORMATIONAL — not an IL-validity defect.
il_errors=0
res_errors=0
il_failed_dlls=()
res_failed_dlls=()
for d in "$OUT2"/Lyric.*.dll; do
  name="$(basename "$d")"
  out="$("$ILVERIFY" "$d" "${refs[@]}" 2>&1 || true)"
  errlines="$(printf '%s\n' "$out" | grep '\[IL\]: Error' || true)"
  [[ -z "$errlines" ]] && continue
  il="$(printf '%s\n' "$errlines" | grep -vE 'ClassLoadGeneral|MissingMethod|FileLoadErrorGeneric' | grep -c '\[IL\]: Error' || true)"
  res="$(printf '%s\n' "$errlines" | grep -cE 'ClassLoadGeneral|MissingMethod|FileLoadErrorGeneric' || true)"
  if [[ "$il" -gt 0 ]]; then
    echo "::group::$name — $il IL-validity error(s)"
    printf '%s\n' "$errlines" | grep -vE 'ClassLoadGeneral|MissingMethod|FileLoadErrorGeneric' | sed 's/^/  /'
    echo "::endgroup::"
    il_errors=$((il_errors + il)); il_failed_dlls+=( "$name:$il" )
  fi
  if [[ "$res" -gt 0 ]]; then
    res_errors=$((res_errors + res)); res_failed_dlls+=( "$name:$res" )
  fi
done

echo ""
echo "[ilverify] ==== summary (arity-consistent self-hosted closure) ===="
echo "[ilverify] DLLs verified                : $emitted"
echo "[ilverify] IL-validity errors (gate)    : $il_errors across ${#il_failed_dlls[@]} DLL(s)"
echo "[ilverify] resolution/extern (info only): $res_errors across ${#res_failed_dlls[@]} DLL(s)"
if [[ "$res_errors" -gt 0 ]]; then
  echo "[ilverify]   (ClassLoadGeneral/MissingMethod/FileLoadErrorGeneric — ilverify"
  echo "[ilverify]    cannot reflection-load extern-FFI BCL targets or optional"
  echo "[ilverify]    assembly refs; not IL-validity defects)"
  for fd in "${res_failed_dlls[@]}"; do echo "[ilverify]   - $fd"; done
fi

if [[ "$il_errors" -eq 0 ]]; then
  echo "[ilverify] OK: self-hosted-emitted IL is verifiable ($emitted DLLs, 0 IL-validity errors)"
  exit 0
fi
echo "[ilverify] FAIL: $il_errors IL-validity error(s) across ${#il_failed_dlls[@]} DLL(s):" >&2
for fd in "${il_failed_dlls[@]}"; do echo "  - $fd" >&2; done
echo "[ilverify] These are self-hosted MSIL emitter bugs (see #3943)." >&2
exit 1
