#!/usr/bin/env bash
# bootstrap.sh — three-stage self-hosting bootstrap for the Lyric compiler
#
# Stage 0:  Build the F# bootstrap compiler (lyric-stage0).
# Stage 1:  Use stage-0 lyric to compile the Lyric-written compiler packages
#           (stdlib, Lyric.Lexer, Lyric.Parser, Lyric.TypeChecker,
#           Lyric.ModeChecker, Lyric.ContractElaborator, Msil.Codegen,
#           Msil.Lowering, Msil.Bridge) into DLLs.
# Stage 2:  Use stage-1 lyric (self-hosted MSIL path) to recompile those same
#           packages from source.  If stage-2 output is byte-for-byte identical
#           to stage-1 output the bootstrap is reproducible.
#
# Usage:
#   ./scripts/bootstrap.sh              # run all three stages
#   ./scripts/bootstrap.sh --stage 0   # build F# compiler only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1
#   ./scripts/bootstrap.sh --stage 2   # all stages including reproducibility check
#   SKIP_VERIFY=1 ./scripts/bootstrap.sh  # skip byte-for-byte comparison

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE0_BIN="$BUILD_DIR/stage0/lyric"
STAGE1_DIR="$BUILD_DIR/stage1"
STAGE2_DIR="$BUILD_DIR/stage2"
COMPILER_DIR="$REPO_ROOT/compiler"
STDLIB_DIR="$REPO_ROOT/stdlib"

MAX_STAGE=2
SKIP_VERIFY="${SKIP_VERIFY:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) MAX_STAGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "[bootstrap] $*"; }
ok() { echo "[bootstrap] OK: $*"; }

# ---------------------------------------------------------------------------
# Stage 0 — F# bootstrap compiler
# ---------------------------------------------------------------------------
stage0() {
  info "Stage 0: building F# bootstrap compiler"
  mkdir -p "$BUILD_DIR/stage0-publish"

  dotnet publish "$COMPILER_DIR/src/Lyric.Cli/Lyric.Cli.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish" \
    --nologo -v q

  # On Linux the published output is a DLL + wrapper script; wire up a
  # convenience symlink so subsequent stages can call `$STAGE0_BIN`.
  if [[ -f "$BUILD_DIR/stage0-publish/lyric" ]]; then
    ln -sf "$BUILD_DIR/stage0-publish/lyric" "$STAGE0_BIN"
  elif [[ -f "$BUILD_DIR/stage0-publish/lyric.dll" ]]; then
    # Fallback: wrap with dotnet exec
    cat > "$STAGE0_BIN" <<'WRAPPER'
#!/usr/bin/env bash
exec dotnet "$(dirname "$0")/stage0-publish/lyric.dll" "$@"
WRAPPER
    chmod +x "$STAGE0_BIN"
  else
    die "publish did not produce a lyric binary in $BUILD_DIR/stage0-publish"
  fi

  ok "Stage 0 complete — $STAGE0_BIN"
}

# ---------------------------------------------------------------------------
# Compile a list of Lyric source files with a given lyric binary.
# compile_files <lyric-bin> <out-dir> <file1> [file2 ...]
# ---------------------------------------------------------------------------
compile_files() {
  local lyric_bin="$1" out_dir="$2"; shift 2
  mkdir -p "$out_dir"
  for src in "$@"; do
    local pkg_dir
    pkg_dir="$(dirname "$src")"
    local base
    base="$(basename "$src" .l)"
    local out="$out_dir/$base.dll"
    info "  compile $src -> $out"
    "$lyric_bin" build "$src" -o "$out" --target dotnet-legacy 2>&1 || \
      die "compile failed: $src"
  done
}

# List of self-hosted compiler source files in dependency order.
# Each entry is relative to $REPO_ROOT.
COMPILER_SOURCES=(
  # Stdlib bundle — built via lyric.toml manifest
  # (handled separately below via `lyric build --manifest`)

  # Self-hosted lexer/parser/type-checker
  "compiler/lyric/lyric/lexer.l"
  "compiler/lyric/lyric/ast.l"
  "compiler/lyric/lyric/parser/parser_ast.l"
  "compiler/lyric/lyric/parser/parser_core.l"
  "compiler/lyric/lyric/parser/parser_exprs.l"
  "compiler/lyric/lyric/parser/parser_items.l"
  "compiler/lyric/lyric/type_checker/type_checker.l"
  "compiler/lyric/lyric/mode_checker/mode_checker.l"
  "compiler/lyric/lyric/contract_elaborator/elaborator.l"
  "compiler/lyric/lyric/test_synth/test_synth.l"

  # MSIL backend
  "compiler/lyric/msil/heaps.l"
  "compiler/lyric/msil/tables.l"
  "compiler/lyric/msil/opcodes.l"
  "compiler/lyric/msil/pe.l"
  "compiler/lyric/msil/assembler.l"
  "compiler/lyric/msil/lowering.l"
  "compiler/lyric/msil/codegen.l"
  "compiler/lyric/msil/bridge.l"
)

# ---------------------------------------------------------------------------
# Stage 1 — compile the Lyric compiler using the F# bootstrap (stage 0)
# ---------------------------------------------------------------------------
stage1() {
  info "Stage 1: compiling Lyric compiler packages with stage-0 lyric"
  mkdir -p "$STAGE1_DIR"

  # Build the stdlib bundle first (multi-package manifest).
  info "  compiling stdlib bundle"
  "$STAGE0_BIN" build --manifest "$STDLIB_DIR/lyric.toml" \
    --output "$STAGE1_DIR/Lyric.Stdlib.dll" --target dotnet-legacy 2>&1 || \
    die "stdlib bundle build failed"

  # Compile each compiler source package.
  for rel in "${COMPILER_SOURCES[@]}"; do
    local src="$REPO_ROOT/$rel"
    local base
    base="$(basename "$src" .l)"
    local out="$STAGE1_DIR/$base.dll"
    [[ -f "$src" ]] || die "source not found: $src"
    info "  compile $rel -> $STAGE1_DIR/$base.dll"
    LYRIC_STD_PATH="$STAGE1_DIR" \
      "$STAGE0_BIN" build "$src" -o "$out" --target dotnet-legacy 2>&1 || \
      die "compile failed: $rel"
  done

  ok "Stage 1 complete — output in $STAGE1_DIR"
}

# ---------------------------------------------------------------------------
# Stage 2 — recompile using the stage-1 self-hosted MSIL emitter
# ---------------------------------------------------------------------------
stage2() {
  info "Stage 2: recompiling Lyric compiler packages with stage-1 self-hosted emitter"

  # The stage-1 lyric binary: same F# host, but --target dotnet now routes
  # through SelfHostedMsil which loads Msil.Bridge from the stage-1 DLLs.
  # We point LYRIC_STD_PATH at stage1/ so the bridge can find stdlib DLLs.
  local stage1_lyric="$STAGE0_BIN"   # same host binary
  mkdir -p "$STAGE2_DIR"

  info "  compiling stdlib bundle (self-hosted MSIL path)"
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$stage1_lyric" build --manifest "$STDLIB_DIR/lyric.toml" \
    --output "$STAGE2_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stage-2 stdlib bundle build failed"

  for rel in "${COMPILER_SOURCES[@]}"; do
    local src="$REPO_ROOT/$rel"
    local base
    base="$(basename "$src" .l)"
    local out="$STAGE2_DIR/$base.dll"
    [[ -f "$src" ]] || die "source not found: $src"
    info "  compile $rel -> $STAGE2_DIR/$base.dll"
    LYRIC_STD_PATH="$STAGE2_DIR" \
      "$stage1_lyric" build "$src" -o "$out" --target dotnet 2>&1 || \
      die "compile failed (stage 2): $rel"
  done

  ok "Stage 2 complete — output in $STAGE2_DIR"

  if [[ "$SKIP_VERIFY" == "1" ]]; then
    info "SKIP_VERIFY=1; skipping byte-for-byte reproducibility check"
    return
  fi

  # ---------------------------------------------------------------------------
  # Reproducibility check: stage-1 and stage-2 DLLs must be identical.
  # A mismatch means the self-hosted emitter produces different output from
  # the F# emitter — this is expected until full MSIL parity is reached.
  # The script reports diffs but does not fail on them; set STRICT_VERIFY=1
  # to treat any diff as a fatal error.
  # ---------------------------------------------------------------------------
  info "Reproducibility check: comparing stage-1 and stage-2 outputs"
  local diffs=0
  for rel in "${COMPILER_SOURCES[@]}"; do
    local base
    base="$(basename "$rel" .l)"
    local f1="$STAGE1_DIR/$base.dll"
    local f2="$STAGE2_DIR/$base.dll"
    if [[ ! -f "$f1" || ! -f "$f2" ]]; then
      echo "  MISSING: $base.dll (one or both stages)" >&2
      diffs=$((diffs + 1))
      continue
    fi
    if ! cmp -s "$f1" "$f2"; then
      echo "  DIFF:    $base.dll (stage-1 vs stage-2 not identical)"
      diffs=$((diffs + 1))
    else
      echo "  MATCH:   $base.dll"
    fi
  done

  if [[ $diffs -eq 0 ]]; then
    ok "Reproducible bootstrap: all DLLs match between stage-1 and stage-2"
  else
    echo "[bootstrap] $diffs DLL(s) differ between stage-1 and stage-2"
    if [[ "${STRICT_VERIFY:-0}" == "1" ]]; then
      die "reproducibility check failed ($diffs diffs)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

stage0
[[ $MAX_STAGE -ge 1 ]] && stage1
[[ $MAX_STAGE -ge 2 ]] && stage2

info "Bootstrap finished (max stage: $MAX_STAGE)"
