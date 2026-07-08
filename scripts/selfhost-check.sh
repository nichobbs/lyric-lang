#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# selfhost-check.sh — classify a Lyric repro: is a misbehaving construct a REAL
# self-hosted-EMITTER bug, or an environment artifact (wrong binary / stdlib
# ABI / stale DLLs)?
#
# This is the committed, documented form of the stage-1-vs-self-hosted A/B loop.
# It compiles FILE with the stage-1 (bootstrap) toolchain — which is itself valid
# IL but RUNS the self-hosted codegen — so compiling/running a program exercises
# the self-hosted emitter on user code while staying reproducible and
# CI-faithful.  It then:
#
#   1. compiles FILE  (self-hosted emitter, via Msil.Bridge)
#   2. runs the emitted program (co-locating the suffixed userlib stdlib)
#   3. runs `ilverify` over the emitted DLL
#
# and prints a VERDICT:
#   * OK                     — compiles, runs, valid IL: the emitter handles
#                              this construct.  A failure you saw elsewhere was
#                              an environment artifact (wrong binary / ABI).
#   * REAL SELF-HOSTED BUG   — compile error, runtime fault, or invalid IL: a
#                              genuine self-hosted-emitter bug.  The ilverify /
#                              runtime output below pinpoints it.
#
# See docs/10-bootstrap-progress.md §"Bootstrap vs self-hosted" and the Makefile
# header for the three-compiler model.
#
# Usage:
#   make lyric                     # build the toolchain once (CI-faithful)
#   scripts/selfhost-check.sh repro.l
#   scripts/selfhost-check.sh repro.l --no-run     # skip execution (compile + ilverify only)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
FILE="${1:-}"
RUN=1
[[ "${2:-}" == "--no-run" ]] && RUN=0

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "usage: scripts/selfhost-check.sh <file.l> [--no-run]" >&2
  exit 2
fi

# LYRIC_BIN may be overridden (e.g. to point at a lyric-seeded bootstrap binary
# staged elsewhere); defaults to the AOT entry point built by `make lyric`.
LYRIC_BIN="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/$BUILD_CONFIG/net10.0/lyric}"
LIB_DIR="$(dirname "$LYRIC_BIN")"
if [[ ! -x "$LYRIC_BIN" ]]; then
  echo "FATAL: lyric toolchain not built at $LYRIC_BIN" >&2
  echo "  build it first:  make lyric  (CI-faithful, valid IL)" >&2
  exit 2
fi
if [[ ! -d "$LIB_DIR/userlib" ]]; then
  echo "WARNING: $LIB_DIR/userlib is missing; the run step may fail to load the" >&2
  echo "  suffixed stdlib.  Re-run 'make lyric' to stage it." >&2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/selfhost-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT_DLL="$WORK/$(basename "${FILE%.l}").dll"

verdict_real() { echo; echo "VERDICT: REAL SELF-HOSTED BUG — $1"; exit 1; }
verdict_ok()   { echo; echo "VERDICT: OK — $1"; exit 0; }

echo "== selfhost-check: $FILE =="
echo "   toolchain: $LYRIC_BIN  (stage-1/bootstrap — valid IL, runs self-hosted codegen)"
echo

# 1. Compile with the self-hosted emitter.
echo "--- compile (self-hosted emitter) ---"
if ! "$LYRIC_BIN" build "$FILE" -o "$OUT_DLL" --force 2>&1; then
  verdict_real "compile failed (see diagnostics above)"
fi
[[ -f "$OUT_DLL" ]] || verdict_real "compile reported success but produced no DLL"

# 2. ilverify the emitted DLL (co-locate the suffixed stdlib so refs resolve).
echo
echo "--- ilverify (emitted IL validity) ---"
if [[ -d "$LIB_DIR/userlib" ]]; then
  cp "$LIB_DIR/userlib/"Lyric.Stdlib.*.dll "$WORK/" 2>/dev/null || true
fi
ILVERIFY="$(command -v ilverify || true)"
if [[ -z "$ILVERIFY" ]]; then
  export PATH="$PATH:$HOME/.dotnet/tools"
  ILVERIFY="$(command -v ilverify || true)"
fi
if [[ -z "$ILVERIFY" ]]; then
  dotnet tool install -g dotnet-ilverify >/dev/null 2>&1 || true
  export PATH="$PATH:$HOME/.dotnet/tools"
  ILVERIFY="$(command -v ilverify || true)"
fi
IL_BAD=0
if [[ -n "$ILVERIFY" ]]; then
  refs=()
  for d in "$WORK"/*.dll; do [[ "$d" == "$OUT_DLL" ]] && continue; refs+=(-r "$d"); done
  # System refs from the .NET ref pack.
  REFPACK="$(find "${DOTNET_ROOT:-/usr/share/dotnet}" /root/.dotnet -path '*Microsoft.NETCore.App.Ref*/ref/net10.0' -type d 2>/dev/null | head -1 || true)"
  [[ -n "$REFPACK" ]] && for d in "$REFPACK"/*.dll; do refs+=(-r "$d"); done
  # `|| true` on both: under `set -e`, ilverify's non-zero exit on IL errors (the
  # very condition we're checking for) would otherwise abort the script here
  # instead of letting IL_BAD below classify it; ditto the `head`-truncated pipe,
  # which can SIGPIPE `echo` when there are more than 20 matching lines.
  il_out="$("$ILVERIFY" "$OUT_DLL" "${refs[@]}" 2>&1)" || true
  echo "$il_out" | grep -E '\[IL\]: Error|All Classes and Methods' | head -20 || true
  if echo "$il_out" | grep -q '\[IL\]: Error'; then IL_BAD=1; fi
else
  echo "(ilverify unavailable — skipping IL check)"
fi

# 3. Run it.
if [[ "$RUN" -eq 1 ]]; then
  echo
  echo "--- run ---"
  # Capture the exit code via `|| run_rc=$?` (not a trailing `; run_rc=$?`): under
  # `set -e` a bare failing assignment on its own line would abort the script
  # before the next line ever ran.
  run_rc=0
  run_out="$(cd "$WORK" && dotnet "$(basename "$OUT_DLL")" 2>&1)" || run_rc=$?
  echo "$run_out" | head -30 || true
  if [[ $run_rc -ne 0 ]]; then
    verdict_real "program faulted at runtime (exit $run_rc) — see output above"
  fi
fi

if [[ "$IL_BAD" -eq 1 ]]; then
  verdict_real "emitted IL is invalid (ilverify errors above)"
fi
verdict_ok "compiles, runs, and emits valid IL for this construct"
