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
  "lyric-compiler/lyric/lexer.l"
  "lyric-compiler/lyric/ast.l"
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
package Lyric.CliBundle
import Lyric.Cli
func main(): Unit { }
EOF

  local driver_out="$driver_dir/Lyric.CliBundle.dll"

  # Snapshot the existing /tmp/lyric-stdlib-* directories so we can
  # identify *the one the upcoming compile creates* unambiguously.
  # Reusing CI runners often leaves stale dirs in /tmp; `ls -dt | head -1`
  # would happily pick one of those if filesystem mtimes were close.
  # `|| true` swallows the non-zero exit when the glob doesn't match —
  # `set -euo pipefail` would otherwise abort here before the post-
  # compile check produces a useful error.
  local pre_snapshot
  pre_snapshot="$(ls -d /tmp/lyric-stdlib-* 2>/dev/null || true)"

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
  # Pattern: /tmp/lyric-stdlib-<pid>/ — see Emitter.fs::stdlibCacheDir.
  local post_snapshot
  post_snapshot="$(ls -d /tmp/lyric-stdlib-* 2>/dev/null || true)"
  local new_dirs
  new_dirs="$(comm -13 \
    <(echo "$pre_snapshot"  | sort) \
    <(echo "$post_snapshot" | sort) \
    | grep -v '^$' || true)"

  local cache_dir
  cache_dir="$(echo "$new_dirs" | head -1)"
  [[ -n "$cache_dir" && -d "$cache_dir" ]] || \
    die "stage-1 CLI bundle: no new /tmp/lyric-stdlib-*/ cache found after compile (pre='$pre_snapshot', post='$post_snapshot')"

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

  # `Lyric.Session.Host.dll` is the path-finder host shim for the #733
  # ecosystem-library restoration plan: it bridges the
  # `Session.Kernel.Net` Lyric kernel to StackExchange.Redis via the
  # `Lyric.Session.RedisStore` static class.  The Lyric-emitted Session
  # DLL carries `@externTarget("Lyric.Session.RedisStore.*")` references
  # that need this DLL on disk at runtime.  Build + copy it alongside
  # the other bootstrap DLLs so the AOT entry-point project + any user
  # program that links `lyric-session` resolves the externs.
  dotnet publish "$COMPILER_DIR/src/Lyric.Session.Host/Lyric.Session.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-session" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-session/Lyric.Session.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-session/Lyric.Session.Host.dll" "$STAGE1_DIR/"
    # The Redis client library is shipped alongside so the host shim's
    # AssemblyRef to StackExchange.Redis resolves at runtime.
    if [[ -f "$BUILD_DIR/stage0-publish-session/StackExchange.Redis.dll" ]]; then
      cp -f "$BUILD_DIR/stage0-publish-session/StackExchange.Redis.dll" "$STAGE1_DIR/"
      copied=$((copied + 1))
    fi
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Session.Host.dll not found in publish output"
  fi

  # `Lyric.Storage.Host.dll` is the Phase-2 host shim for #733 — bridges
  # the lyric-storage local-filesystem backend through `Lyric.Storage.LocalHost`.
  # No NuGet dependencies (System.IO only); S3 / Azure Blob shims land as
  # separate phases under #782 with their own Testcontainers infrastructure.
  dotnet publish "$COMPILER_DIR/src/Lyric.Storage.Host/Lyric.Storage.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-storage" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-storage/Lyric.Storage.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-storage/Lyric.Storage.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Storage.Host.dll not found in publish output"
  fi

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

  # `Lyric.Mail.Host.dll` is the Phase-4 host shim for #733 — bridges the
  # lyric-mail SMTP backend through `Lyric.Mail.SmtpHost` (BCL System.Net.Mail).
  # No NuGet dependencies; MailKit / SES / SendGrid shims land as separate
  # phases under #780 with their own Testcontainers infrastructure.
  dotnet publish "$COMPILER_DIR/src/Lyric.Mail.Host/Lyric.Mail.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-mail" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-mail/Lyric.Mail.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-mail/Lyric.Mail.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Mail.Host.dll not found in publish output"
  fi

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

  # `Lyric.Ws.Host.dll` is the Phase-6 host shim for #733 — bridges the
  # lyric-ws in-process connection registry and the sliding-window rate
  # limiter through `Lyric.Ws.RegistryHost` and `Lyric.Ws.RateLimitHost`.
  # No NuGet dependencies; real ASP.NET Core WebSocket integration lands
  # as a follow-up under #778 once the lyric-web Kestrel shim is ready.
  dotnet publish "$COMPILER_DIR/src/Lyric.Ws.Host/Lyric.Ws.Host.fsproj" \
    --configuration Release \
    --output "$BUILD_DIR/stage0-publish-ws" \
    --nologo -v q
  if [[ -f "$BUILD_DIR/stage0-publish-ws/Lyric.Ws.Host.dll" ]]; then
    cp -f "$BUILD_DIR/stage0-publish-ws/Lyric.Ws.Host.dll" "$STAGE1_DIR/"
    copied=$((copied + 1))
  else
    die "stage-1 CLI bundle: Lyric.Ws.Host.dll not found in publish output"
  fi

  info "  copied $copied DLLs into $STAGE1_DIR"

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

# ---------------------------------------------------------------------------
# Stage 2 — recompile using the stage-1 self-hosted MSIL emitter
# ---------------------------------------------------------------------------
stage2() {
  info "Stage 2: recompiling Lyric compiler packages with stage-1 self-hosted emitter"

  # NOTE (Track A, A1.2): stage 2 still walks the legacy COMPILER_SOURCES
  # list, which expects per-source-file DLL names (lexer.dll, parser.dll,
  # …) — but stage 1's CLI-bundle precompile emits per-package DLLs
  # named `Lyric.Lyric.<Pkg>.dll`.  Until stage 2 is rewritten to drive
  # the same `import Lyric.Cli` driver and compare bundles file-by-file,
  # the reproducibility check below cannot run meaningfully.  Rather
  # than silently report MISSING for every entry and exit 0, the check
  # now fails loudly with a clear message and points the user at
  # `SKIP_VERIFY=1` if they want to opt out.
  #
  # If you're here because CI failed: set `SKIP_VERIFY=1` to skip the
  # check, or contribute the rewrite (snapshot the `Lyric.Lyric.<Pkg>.dll`
  # outputs of stage 1's CLI-bundle, recompile the driver in stage 2,
  # and compare each artefact across the two stages).
  if [[ "$SKIP_VERIFY" != "1" ]]; then
    die "stage 2 reproducibility check is incompatible with the A1.2 stage-1 layout; set SKIP_VERIFY=1 to skip, or rewrite stage2() to compare the CLI-bundle outputs"
  fi
  info "SKIP_VERIFY=1; skipping the reproducibility recompile entirely"
  return 0
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
