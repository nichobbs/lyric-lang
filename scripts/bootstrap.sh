#!/usr/bin/env bash
# bootstrap.sh — three-stage self-hosting bootstrap for the Lyric compiler
#
# Stage 0:  Build the F# bootstrap compiler (lyric-stage0).
# Stage 1:  Use stage-0 lyric to compile the Lyric-written compiler packages
#           (stdlib, Lyric.Lexer, Lyric.Parser, Lyric.TypeChecker,
#           Lyric.ModeChecker, Lyric.ContractElaborator, Msil.Codegen,
#           Msil.Lowering, Msil.Bridge) into DLLs.  Then drive the F#
#           emitter via a tiny `import Lyric.Cli` driver so it precompiles
#           the full CLI dependency closure (cli.l + ~25 Lyric packages)
#           and copies the artefacts into `.bootstrap/stage1/`.  These are
#           the DLLs Track A's AOT entry-point project will reference.
# Stage 2:  [BLOCKED — A1.2 stage-2 rewrite pending: snapshot the
#           `Lyric.Lyric.*.dll` outputs from stage 1, recompile the
#           CLI-bundle driver via stage-1 lyric, then compare bundles
#           file-by-file.  The current `stage2()` hard-fails because
#           the COMPILER_SOURCES loop assumes per-source DLL names
#           (`lexer.dll`, …) that no longer match stage 1's per-
#           package output.  Set `SKIP_VERIFY=1` to bypass until the
#           rewrite lands.]
#
# Usage:
#   ./scripts/bootstrap.sh              # all stages (stage 2 fails unless SKIP_VERIFY=1)
#   ./scripts/bootstrap.sh --stage 0   # build F# compiler only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1
#   ./scripts/bootstrap.sh --stage 2   # all stages; stage 2 currently blocked
#   SKIP_VERIFY=1 ./scripts/bootstrap.sh  # skip the (blocked) reproducibility check
#   SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh  # stage 1 stops after the compiler-package
#                                              loop; the CLI bundle step is skipped.
#                                              Useful when iterating on a single
#                                              compiler package.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE0_BIN="$BUILD_DIR/stage0/lyric"
STAGE1_DIR="$BUILD_DIR/stage1"
STAGE2_DIR="$BUILD_DIR/stage2"
COMPILER_DIR="$REPO_ROOT/bootstrap"
STDLIB_DIR="$REPO_ROOT/lyric-stdlib"

# Temp base used by the F# emitter's per-process stdlib cache
# (`Emitter.fs::stdlibCacheDir` → `Path.GetTempPath()`).  On Unix .NET's
# GetTempPath() returns $TMPDIR when set, else "/tmp".  We mirror that exactly
# so the CLI-bundle snapshot below globs the same directory the emitter writes
# to — otherwise a non-/tmp $TMPDIR makes the snapshot miss the cache and the
# build dies (this is why callers previously had to force `TMPDIR=/tmp`).
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"   # strip any trailing slash so the glob is well-formed

MAX_STAGE=2
SKIP_VERIFY="${SKIP_VERIFY:-0}"
SKIP_CLI_BUNDLE="${SKIP_CLI_BUNDLE:-0}"
SKIP_COREREF_REWRITE="${SKIP_COREREF_REWRITE:-0}"

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
  # `$STAGE0_BIN` is `$BUILD_DIR/stage0/lyric`; create the parent dir
  # before symlinking into it.
  mkdir -p "$(dirname "$STAGE0_BIN")"

  # Optional cache reuse (CI): when STAGE0_REUSE_PUBLISHED=1 and a published
  # binary is already present (restored from an actions/cache keyed on the
  # exact hash of every F# source), skip the Release publish.  The cache key
  # is content-addressed with NO prefix fallback, so a restored output is
  # guaranteed to correspond to the current F# sources; a miss restores
  # nothing and we rebuild below.  Local dev never sets the flag, so it always
  # rebuilds and can't be fooled by a stale `.bootstrap/`.
  if [[ "${STAGE0_REUSE_PUBLISHED:-0}" == "1" \
        && ( -f "$BUILD_DIR/stage0-publish/lyric" \
             || -f "$BUILD_DIR/stage0-publish/lyric.dll" ) ]]; then
    info "  reusing cached stage-0 publish (STAGE0_REUSE_PUBLISHED=1)"
  else
    dotnet publish "$COMPILER_DIR/src/Lyric.Cli/Lyric.Cli.fsproj" \
      --configuration Release \
      --output "$BUILD_DIR/stage0-publish" \
      --nologo -v q
  fi

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
  "lyric-compiler/lyric/lexer.l"
  "lyric-compiler/lyric/parser/parser_ast.l"
  "lyric-compiler/lyric/parser/parser_core.l"
  "lyric-compiler/lyric/parser/parser_exprs.l"
  "lyric-compiler/lyric/parser/parser_items.l"
  "lyric-compiler/lyric/type_checker/typechecker_checker.l"
  "lyric-compiler/lyric/type_checker/typechecker_constfold.l"
  "lyric-compiler/lyric/type_checker/typechecker_exprs.l"
  "lyric-compiler/lyric/type_checker/typechecker_resolver.l"
  "lyric-compiler/lyric/type_checker/typechecker_scope.l"
  "lyric-compiler/lyric/type_checker/typechecker_signature.l"
  "lyric-compiler/lyric/type_checker/typechecker_stmts.l"
  "lyric-compiler/lyric/type_checker/typechecker_symbols.l"
  "lyric-compiler/lyric/type_checker/typechecker_types.l"
  "lyric-compiler/lyric/mode_checker/modechecker_mode.l"
  "lyric-compiler/lyric/mode_checker/modechecker_check.l"
  "lyric-compiler/lyric/contract_elaborator/elaborator.l"
  "lyric-compiler/lyric/propagate.l"
  "lyric-compiler/lyric/test_synth/test_synth.l"

  # MSIL backend
  "lyric-compiler/msil/heaps.l"
  "lyric-compiler/msil/tables.l"
  "lyric-compiler/msil/opcodes.l"
  "lyric-compiler/msil/pe.l"
  "lyric-compiler/msil/assembler.l"
  "lyric-compiler/msil/lowering.l"
  "lyric-compiler/msil/codegen.l"
  "lyric-compiler/msil/bridge.l"
)

# ---------------------------------------------------------------------------
# Stage 1 — compile the Lyric compiler using the F# bootstrap (stage 0)
# ---------------------------------------------------------------------------
stage1() {
  info "Stage 1: compiling Lyric compiler packages with stage-0 lyric"
  mkdir -p "$STAGE1_DIR"

  # Build the stdlib bundle first (multi-package manifest).
  # Track A A1.4: the F# user-facing `lyric build --manifest`
  # dispatcher is gone; stage 1 drives the multi-package compile
  # through the bootstrap-only `--internal-manifest-build` flag
  # which reads `lyric.toml` and feeds the package list straight
  # to `Emitter.emitProject`.
  info "  compiling stdlib bundle"
  "$STAGE0_BIN" --internal-manifest-build "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE1_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stdlib bundle build failed"

  if [[ "$SKIP_CLI_BUNDLE" != "1" ]]; then
    # Track A (A1.2) — precompile cli.l + the full Lyric.Cli dependency
    # closure into $STAGE1_DIR.  The F# emitter's stdlib auto-resolve
    # discovers every transitive import (lexer, parser, type-checker,
    # mode-checker, contract-elaborator, MSIL backend, manifest, pack,
    # workspace, gitdep, lockfile, generator, emitter, fmt, lint,
    # verifier, doc, contract-meta, repl, test-synth, bench-synth,
    # openapi, …) from a one-line driver and emits each as a DLL.
    # We then copy the artefacts to $STAGE1_DIR.
    #
    # This single step replaces the old manual COMPILER_SOURCES compile
    # loop — the F# emitter does dependency ordering correctly and
    # there's no value in the script re-implementing it.
    stage1_cli_bundle
  else
    info "SKIP_CLI_BUNDLE=1; skipping the CLI dependency-closure precompile"
  fi

  ok "Stage 1 complete — output in $STAGE1_DIR"
}

# ---------------------------------------------------------------------------
# Stage 1 — CLI bundle precompile (Track A, A1.2)
#
# Compile a tiny driver program that does `import Lyric.Cli`.  The F#
# emitter's stdlib auto-resolve discovers cli.l's full transitive
# dependency closure (~25 Lyric packages plus the existing compiler
# packages built above) and emits each one as a DLL in its per-process
# scratch cache.  We then copy those DLLs into $STAGE1_DIR so the
# stage-1 layout contains every artefact the AOT entry-point project
# (Track A, A1.3) will reference.
#
# This step is idempotent: re-running it just overwrites the same DLLs.
# It writes to a unique sub-dir under $BUILD_DIR/tmp so concurrent
# bootstraps don't race.
# ---------------------------------------------------------------------------
stage1_cli_bundle() {
  info "Stage 1 (CLI bundle): precompiling Lyric.Cli + transitive deps"

  local driver_dir="$BUILD_DIR/stage1-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the bootstrap CLI-bundle precompile.
// Importing Lyric.Cli forces the F# emitter to compile cli.l and
// every transitively-imported Lyric package into its stdlib cache.
//
// Std.Time / Std.Math are imported *directly* because neither appears in
// the direct or transitive import closure of Lyric.Cli.  (Lyric.BenchSynth
// emits the string "import Std.Time" into synthesised benchmark source,
// but that is a code-generation artefact, not an import edge the emitter
// sees here.)  Without a direct import the F# emitter never visits these
// modules during the CLI-bundle precompile, so Lyric.Stdlib.Time(.Host) /
// Math(.Host) DLLs never land in $STAGE1_DIR — and every ecosystem library
// that imports Std.Time or Std.Math (lyric-session, lyric-auth,
// lyric-cache, …) then fails at run time with "Could not load file or
// assembly 'Lyric.Stdlib.Time'".
//
// Std.Testing.Mocking is imported directly so Lyric.Stdlib.Testing.Mocking.dll
// lands in $STAGE1_DIR.  The testing self-tests (stubbable_self_test.l etc.)
// import this package and the compiled test DLL then references it at runtime
// — without a standalone DLL the CLR load fails with a file-not-found error.
package Lyric.CliBundle
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

  local driver_out="$driver_dir/Lyric.CliBundle.dll"

  # Snapshot the existing $TMP_BASE/lyric-stdlib-* directories so we can
  # identify *the one the upcoming compile creates* unambiguously.
  # Reusing CI runners often leaves stale dirs in the temp base; `ls -dt
  # | head -1` would happily pick one of those if filesystem mtimes were
  # close.  `|| true` swallows the non-zero exit when the glob doesn't
  # match — `set -euo pipefail` would otherwise abort here before the
  # post-compile check produces a useful error.
  local pre_snapshot
  pre_snapshot="$(ls -d "$TMP_BASE"/lyric-stdlib-* 2>/dev/null || true)"

  # Force the F# emitter via `--internal-build`.  The driver has a
  # `func main(): Unit { }` so it satisfies the F# emitter's executable
  # contract; we don't care about running it, only about the side effect
  # of populating the per-process stdlib cache with every Lyric package
  # the driver transitively imports.
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$STAGE0_BIN" --internal-build "$driver_dir/driver.l" -o "$driver_out" \
    --target dotnet 2>&1 || \
    die "stage-1 CLI-bundle driver compile failed"

  # Locate the cache dir the compile created: take all current matches,
  # subtract the pre-compile snapshot, expect exactly one new entry.
  # Pattern: $TMP_BASE/lyric-stdlib-<pid>/ — see Emitter.fs::stdlibCacheDir.
  local post_snapshot
  post_snapshot="$(ls -d "$TMP_BASE"/lyric-stdlib-* 2>/dev/null || true)"
  local new_dirs
  new_dirs="$(comm -13 \
    <(echo "$pre_snapshot"  | sort) \
    <(echo "$post_snapshot" | sort) \
    | grep -v '^$' || true)"

  local cache_dir
  cache_dir="$(echo "$new_dirs" | head -1)"
  [[ -n "$cache_dir" && -d "$cache_dir" ]] || \
    die "stage-1 CLI bundle: no new $TMP_BASE/lyric-stdlib-*/ cache found after compile (pre='$pre_snapshot', post='$post_snapshot')"

  info "  CLI bundle cache: $cache_dir"
  local copied=0
  for f in "$cache_dir"/*.dll; do
    [[ -f "$f" ]] || continue
    cp -f "$f" "$STAGE1_DIR/"
    copied=$((copied + 1))
  done

  # `Lyric.Jvm.Hosts.dll` is a hand-written F# project (provides the
  # `Jvm.Hosts.*` extern surface that the JVM kernel calls into), not
  # a Lyric-emitted artefact, so it doesn't land in the F# emitter's
  # stdlib cache.  But Msil.Lowering / Msil.Codegen reference it
  # statically.  Copy it from the stage-0 publish output so stage 1
  # contains a complete reference set for the AOT entry-point project.
  if [[ -f "$BUILD_DIR/stage0-publish/Lyric.Jvm.Hosts.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/Lyric.Jvm.Hosts.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Jvm.Hosts.dll not found in stage-0 publish"
  fi

  # `FSharp.Core.dll` — `Lyric.Jvm.Hosts` (above) is F#, so the in-process
  # `--target jvm` build path (Lyric.Emitter -> Jvm.Bridge -> Jvm.Kernel ->
  # Jvm.Hosts) needs the F# runtime deployed beside the AOT binary.  The
  # MSIL kernel is pure-Lyric and never loads it, so this is JVM-only.  The
  # AOT csproj references `.bootstrap/stage1/FSharp.Core.dll`.
  if [[ -f "$BUILD_DIR/stage0-publish/FSharp.Core.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/FSharp.Core.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: FSharp.Core.dll not found in stage-0 publish"
  fi

  # `Lyric.Emitter.dll` (the F# bootstrap emitter) hosts a small set of
  # helper types — `ConsoleHelper`, `ProcessCapture`, `VerifierEnv`,
  # `HttpClientHost` — that the stdlib kernel modules `@externTarget`
  # against (see `lyric-stdlib/std/_kernel/{console,process_capture,
  # verifier_env,http}_host.l`).  The Lyric-emitted stdlib DLLs carry
  # AssemblyRefs to `Lyric.Emitter` for those externs, so at runtime
  # any program that prints to stderr / launches a subprocess / reads
  # an env var / makes an HTTP call needs the emitter DLL on disk.
  # Stage 0 publishes it; stage 1 copies it alongside the other
  # bootstrap DLLs so the AOT entry-point project resolves the externs.
  if [[ -f "$BUILD_DIR/stage0-publish/Lyric.Emitter.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/Lyric.Emitter.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Emitter.dll not found in stage-0 publish"
  fi

  # `Lyric.Session.Host` is gone — `Session.Kernel.Net` now binds
  # StackExchange.Redis directly via `@externTarget` in native Lyric
  # (`lyric-session/src/_kernel/net/session_kernel.l`, #1777).
  # No F# shim is published or copied into the stage-1 bundle.
  # StackExchange.Redis.dll is resolved at user-program build time via
  # the `[nuget]` entry in lyric-session/lyric.toml.

  # `Lyric.Storage.Host` is gone — the lyric-storage local-filesystem
  # backend now binds the BCL externs (System.IO.File, System.IO.Directory,
  # System.IO.Path, System.Convert, System.Security.Cryptography.MD5)
  # directly from `Storage.Kernel.Net`.  No F# host shim is published or
  # copied into the stage-1 bundle.  S3 / Azure Blob backends return
  # `NOT_IMPLEMENTED` until their native NuGet SDK bindings land.


  # `Lyric.Jobs.Host.dll` is the Phase-3 host shim for #733 — bridges the
  # lyric-jobs in-process scheduler through `Lyric.Jobs.InProcessHost` and
  # the threading primitives through `Lyric.Jobs.Threading`.  No NuGet
  # dependencies (BCL System.Threading + DateTimeOffset only); Hangfire and
  # Quartz.NET shims land as separate phases under #781 with their own
  # durable-persistence Testcontainers infrastructure.
  dotnet publish "$COMPILER_DIR/src/Lyric.Jobs.Host/Lyric.Jobs.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-jobs" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-jobs/Lyric.Jobs.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-jobs/Lyric.Jobs.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Jobs.Host.dll not found in publish output"
  fi

  # `Lyric.Mail.Host` is gone — the lyric-mail SMTP backend now binds
  # `System.Net.Mail` directly from its kernel.  No F# host shim is
  # published or copied into the stage-1 bundle.

  # `Lyric.Mq.Host.dll` is the Phase-5 host shim for #733 — bridges the
  # lyric-mq in-memory queue backend through `Lyric.Mq.InMemoryHost`.  No
  # NuGet dependencies (ConcurrentQueue + ConcurrentDictionary only);
  # RabbitMQ / Azure Service Bus / SQS / Kafka driver shims land as
  # separate phases under #779.
  dotnet publish "$COMPILER_DIR/src/Lyric.Mq.Host/Lyric.Mq.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-mq" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-mq/Lyric.Mq.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-mq/Lyric.Mq.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Mq.Host.dll not found in publish output"
  fi

  # `Lyric.Web.Host.dll` is the Phase-8 host shim for #733 — bridges the
  # lyric-web `Web.start` entry point through `Lyric.Web.HttpListenerHost`
  # using BCL System.Net.HttpListener.  The path-finder actually binds
  # the port (fixing the silent no-op from #784) and serves a JSON
  # description of the routing table for every request.  Real ASP.NET
  # Core Kestrel + minimal-API dispatch lands as a follow-up.
  dotnet publish "$COMPILER_DIR/src/Lyric.Web.Host/Lyric.Web.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-web" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-web/Lyric.Web.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-web/Lyric.Web.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Web.Host.dll not found in publish output"
  fi

  info "  copied $copied DLLs into $STAGE1_DIR"

  # Remove every per-host scratch publish directory now that the shim DLLs
  # have been copied into $STAGE1_DIR.  Leaving them in place accumulates
  # ~100 MB across repeat bootstraps.  We glob `stage0-publish-*` so new
  # ecosystem libraries are cleaned automatically without touching this
  # script (#1125).  The shared `stage0-publish` directory itself is
  # intentionally kept because the generated apphost stub points at
  # `stage0-publish/lyric.dll`.
  shopt -s nullglob
  scratch_dirs=("$BUILD_DIR"/stage0-publish-*)
  shopt -u nullglob
  if (( ${#scratch_dirs[@]} > 0 )); then
    rm -rf "${scratch_dirs[@]}"
  fi

  # Sanity check: Lyric.Lyric.Cli.dll must land in stage1/.  If it
  # doesn't, the F# emitter's stdlib-cache layout has changed and this
  # script needs to be updated.
  [[ -f "$STAGE1_DIR/Lyric.Lyric.Cli.dll" ]] || \
    die "stage-1 CLI bundle: Lyric.Lyric.Cli.dll not found in $STAGE1_DIR after copy"

  # Track A A1.3: retarget Lyric-emitted DLLs' AssemblyRefs from
  # `System.Private.CoreLib` (the unified CoreCLR runtime assembly)
  # to the matching public-facade reference assemblies (System.Runtime,
  # System.Collections, System.Console, mscorlib, ...).  Without this
  # rewrite the AOT entry-point project can't reference the
  # stage-1 DLLs as compile-time inputs — the C# compiler refuses to
  # accept refs whose AssemblyRef table points at System.Private.CoreLib.
  if [[ "$SKIP_COREREF_REWRITE" != "1" ]]; then
    info "  retargeting System.Private.CoreLib refs -> public facades"
    dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE1_DIR"/*.dll \
      > "$BUILD_DIR/rewrite-corelib-refs.log" 2>&1 || \
      die "stage-1 CLI bundle: corelib-ref rewrite failed (see $BUILD_DIR/rewrite-corelib-refs.log)"
  else
    info "SKIP_COREREF_REWRITE=1; leaving stage-1 DLLs with raw CoreLib refs"
  fi

  ok "Stage 1 CLI bundle complete — Lyric.Lyric.Cli.dll + $((copied - 1)) deps in $STAGE1_DIR"
}

compare_stage1_stage2_dlls() {
  local f1="$1"
  local f2="$2"
  local python_bin
  python_bin="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  if [[ -z "$python_bin" ]]; then
    die "python3 or python is required for the stage-2 reproducibility comparison"
  fi
  "$python_bin" - "$f1" "$f2" <<'PY' >/dev/null
from pathlib import Path
import sys
f1_path = Path(sys.argv[1])
f2_path = Path(sys.argv[2])
f1 = bytearray(f1_path.read_bytes())
f2 = bytearray(f2_path.read_bytes())
if len(f1) != len(f2):
    sys.exit(1)
for off in range(0x88, 0x8c):
    f1[off] = 0
    f2[off] = 0
first = next((i for i in range(0x90, len(f1)) if f1[i] != f2[i]), None)
if first is not None:
    end = first
    while end < len(f1) and f1[end] != f2[end]:
        end += 1
    if end - first != 16:
        sys.exit(1)
    for off in range(first, end):
        f1[off] = 0
        f2[off] = 0
if f1 != f2:
    sys.exit(1)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Stage 2 — recompile using the stage-1 self-hosted MSIL emitter
# ---------------------------------------------------------------------------
stage2() {
  info "Stage 2: recompiling Lyric compiler packages with stage-1 self-hosted emitter"

  # New approach: reproduce the CLI-bundle precompile under the
  # stage-1 self-hosted layout and compare the per-package DLLs
  # produced by stage-1 and stage-2 file-by-file.

  if [[ "$SKIP_VERIFY" == "1" ]]; then
    info "SKIP_VERIFY=1; skipping stage-2 reproducibility check"
    return 0
  fi

  mkdir -p "$STAGE2_DIR"

  # First, compile the stdlib bundle via the self-hosted path so we
  # produce the top-level Lyric.Stdlib.dll the stage-1 bundle contains.
  info "  compiling stdlib bundle (self-hosted MSIL path)"
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$STAGE0_BIN" --internal-manifest-build "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE2_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stage-2 stdlib bundle build failed"

  # Create a short driver (same as stage1_cli_bundle) but run it with
  # LYRIC_STD_PATH pointing at $STAGE1_DIR so the SelfHostedMsil bridge
  # loads the stage-1 DLLs and the emitted cache contains the per-package
  # outputs we want to compare.
  local driver_dir="$BUILD_DIR/stage2-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the stage-2 CLI-bundle precompile.
package Lyric.CliBundleStage2
import Lyric.Cli
import Std.Time
import Std.Math
func main(): Unit { }
EOF

  local driver_out="$driver_dir/Lyric.CliBundleStage2.dll"

  # Snapshot pre-existing cache dirs so we can identify the new one.
  local pre_snapshot
  pre_snapshot="$(ls -d "$TMP_BASE"/lyric-stdlib-* 2>/dev/null || true)"

  # Force the build via the host binary but direct the stdlib path
  # at the stage-1 outputs so the bridge compiles against stage-1.
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$STAGE0_BIN" --internal-build "$driver_dir/driver.l" -o "$driver_out" \
    --target dotnet 2>&1 || \
    die "stage-2 CLI-bundle driver compile failed"

  local post_snapshot
  post_snapshot="$(ls -d "$TMP_BASE"/lyric-stdlib-* 2>/dev/null || true)"
  local new_dirs
  new_dirs="$(comm -13 \
    <(echo "$pre_snapshot"  | sort) \
    <(echo "$post_snapshot" | sort) \
    | grep -v '^$' || true)"

  local cache_dir
  cache_dir="$(echo "$new_dirs" | head -1)"
  [[ -n "$cache_dir" && -d "$cache_dir" ]] || \
    die "stage-2 CLI bundle: no new $TMP_BASE/lyric-stdlib-*/ cache found after compile (pre='$pre_snapshot', post='$post_snapshot')"

  info "  stage-2 CLI bundle cache: $cache_dir"
  local copied=0
  for f in "$cache_dir"/*.dll; do
    [[ -f "$f" ]] || continue
    cp -f "$f" "$STAGE2_DIR/"
    copied=$((copied + 1))
  done

  # Copy the same host shim DLLs the stage-1 bundle includes so the two
  # directories contain the same reference set for a fair comparison.
  if [[ -f "$BUILD_DIR/stage0-publish/Lyric.Jvm.Hosts.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/Lyric.Jvm.Hosts.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: Lyric.Jvm.Hosts.dll not found in stage-0 publish"
  fi

  if [[ -f "$BUILD_DIR/stage0-publish/FSharp.Core.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/FSharp.Core.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: FSharp.Core.dll not found in stage-0 publish"
  fi

  if [[ -f "$BUILD_DIR/stage0-publish/Lyric.Emitter.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish/Lyric.Emitter.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: Lyric.Emitter.dll not found in stage-0 publish"
  fi

  # Lyric.Session.Host is gone — see stage-1 comment above (#1777).

  dotnet publish "$COMPILER_DIR/src/Lyric.Jobs.Host/Lyric.Jobs.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-jobs" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-jobs/Lyric.Jobs.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-jobs/Lyric.Jobs.Host.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: Lyric.Jobs.Host.dll not found in publish output"
  fi

  dotnet publish "$COMPILER_DIR/src/Lyric.Mq.Host/Lyric.Mq.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-mq" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-mq/Lyric.Mq.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-mq/Lyric.Mq.Host.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: Lyric.Mq.Host.dll not found in publish output"
  fi

  dotnet publish "$COMPILER_DIR/src/Lyric.Web.Host/Lyric.Web.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-web" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-web/Lyric.Web.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-web/Lyric.Web.Host.dll" "$STAGE2_DIR/"
    copied=$((copied + 1))
  else
    die "stage-2 CLI bundle: Lyric.Web.Host.dll not found in publish output"
  fi

  info "  copied $copied DLLs into $STAGE2_DIR"

  # Retarget System.Private.CoreLib refs -> public facades so the stage-2
  # outputs match the stage-1 rewrite step.  This mirrors the stage-1
  # rewrite performed in `stage1_cli_bundle()`.
  if [[ "$SKIP_COREREF_REWRITE" != "1" ]]; then
    info "  retargeting System.Private.CoreLib refs -> public facades (stage-2)"
    dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE2_DIR"/*.dll \
      > "$BUILD_DIR/rewrite-corelib-refs-stage2.log" 2>&1 || \
      die "stage-2 CLI bundle: corelib-ref rewrite failed (see $BUILD_DIR/rewrite-corelib-refs-stage2.log)"
  else
    info "SKIP_COREREF_REWRITE=1; leaving stage-2 DLLs with raw CoreLib refs"
  fi

  # Sanity check: Lyric.Lyric.Cli.dll must land in stage2/.  If it
  # doesn't, something in the emitter cache layout changed and the
  # comparison will be meaningless.
  [[ -f "$STAGE2_DIR/Lyric.Lyric.Cli.dll" ]] || \
    die "stage-2 CLI bundle: Lyric.Lyric.Cli.dll not found in $STAGE2_DIR after copy"

  # -------------------------------------------------------------------------
  # Compare stage-1 and stage-2 outputs file-by-file.
  # -------------------------------------------------------------------------
  info "Reproducibility check: comparing stage-1 and stage-2 bundle outputs"
  local diffs=0
  shopt -s nullglob
  for f in "$STAGE1_DIR"/*.dll; do
    local name
    name="$(basename "$f")"
    local f1="$STAGE1_DIR/$name"
    local f2="$STAGE2_DIR/$name"
    if [[ ! -f "$f2" ]]; then
      echo "  MISSING: $name (stage-2 missing)" >&2
      diffs=$((diffs + 1))
      continue
    fi
    if ! compare_stage1_stage2_dlls "$f1" "$f2"; then
      echo "  DIFF:    $name (stage-1 vs stage-2 differ after normalizing known metadata fields)"
      diffs=$((diffs + 1))
    else
      echo "  MATCH:   $name"
    fi
  done
  shopt -u nullglob

  if [[ $diffs -eq 0 ]]; then
    ok "Reproducible bootstrap: all DLLs match between stage-1 and stage-2"
  else
    echo "[bootstrap] $diffs DLL(s) differ between stage-1 and stage-2"
    if [[ "${STRICT_VERIFY:-0}" == "1" ]]; then
      die "reproducibility check failed ($diffs diffs)"
    fi
  fi
}

# The legacy stage 2 body — kept for reference until the A1.2 stage-2
# rewrite lands.  Not currently reachable because
# stage2() above hard-fails (or returns when SKIP_VERIFY=1); delete
# this function entirely once the A1.2 rewrite ships its replacement
# (`import Lyric.Cli` bundle compile + per-package byte-for-byte diff).
_stage2_legacy() {
  info "Stage 2: recompiling Lyric compiler packages with stage-1 self-hosted emitter"

  # The stage-1 lyric binary: same F# host, but --target dotnet now routes
  # through SelfHostedMsil which loads Msil.Bridge from the stage-1 DLLs.
  # We point LYRIC_STD_PATH at stage1/ so the bridge can find stdlib DLLs.
  local stage1_lyric="$STAGE0_BIN"   # same host binary
  mkdir -p "$STAGE2_DIR"

  info "  compiling stdlib bundle (self-hosted MSIL path)"
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$stage1_lyric" --internal-manifest-build "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE2_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
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
