#!/usr/bin/env bash
# bootstrap.sh — three-stage self-hosting bootstrap for the Lyric compiler
#
# Stage 0:  Build the F# bootstrap compiler (lyric-stage0).
# Stage 1:  Use stage-0 lyric to compile the Lyric-written compiler packages
#           (stdlib, Lyric.Lexer, Lyric.Parser, Lyric.TypeChecker,
#           Lyric.ModeChecker, Lyric.ContractElaborator, Msil.Codegen,
#           Msil.Lowering, Msil.Bridge) into DLLs.  Then drive the F#
#           emitter via a tiny `import Lyric.Cli` driver so it precompiles
#           the full CLI dependency closure (cli/ + ~25 Lyric packages)
#           and copies the artefacts into `.bootstrap/stage1/`.  These are
#           the DLLs Track A's AOT entry-point project will reference.
# Stage 2:  Reproducibility verification, in two parts:
#
#           (a) TRUST-ANCHOR GATE (STRICT) — build the full self-hosted stdlib
#               bundle (`lyric-stdlib/lyric.full.toml`) TWICE via the AOT
#               `lyric` binary (which routes `--target dotnet` through the
#               self-hosted `Msil.Bridge`) and assert the two images are
#               byte-for-byte identical with an exact `cmp`.  The self-hosted
#               emitter is deterministic by construction — fixed Module MVID
#               (lowering.l) and zero PE TimeDateStamp (assembler.l), no
#               wall-clock baked into any heap or resource — so this passes
#               with no normalization.  This is the property a signed,
#               reproducible release depends on (Q-dist-001); a regression
#               here FAILS the build.  See scripts/verify-reproducible-emit.sh.
#
#           (b) STAGE-0 DIAGNOSTIC (informational) — compare the stage-1 and
#               stage-2 F#-emitted CLI-bundle DLLs after precisely zeroing the
#               intrinsic identity fields (Module MVID via the #GUID heap, PE
#               TimeDateStamp, PE checksum) using an ECMA-335-aware normalizer.
#               The F# stage-0 emitter is non-reproducible BY DESIGN — random
#               MVID, real PE timestamp, and a `DateTime.UtcNow` `build_date`
#               embedded in `Lyric.SdkVersion` — and is frozen on a deletion
#               schedule (no new F#), so this part is reported but NEVER fatal.
#               It exists to track stage-0 drift until the F# path is deleted.
#
# Usage:
#   ./scripts/bootstrap.sh              # all stages; stage 2 gate (a) is STRICT
#   ./scripts/bootstrap.sh --stage 0   # build F# compiler only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1
#   ./scripts/bootstrap.sh --stage 2   # all stages incl. reproducibility gate
#   SKIP_VERIFY=1 ./scripts/bootstrap.sh  # skip ALL of stage-2 verification
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

  # On Linux the published output is a native binary. On Windows, it's a DLL.
  # Use copy instead of symlink for Windows compatibility.
  if [[ -f "$BUILD_DIR/stage0-publish/lyric" ]]; then
    # Native binary on Linux/macOS
    ln -sf "$BUILD_DIR/stage0-publish/lyric" "$STAGE0_BIN"
  elif [[ -f "$BUILD_DIR/stage0-publish/lyric.dll" ]]; then
    # Windows DLL: copy it (symlinks don't work reliably on Windows)
    cp "$BUILD_DIR/stage0-publish/lyric.dll" "$STAGE0_BIN"
  else
    die "publish did not produce a lyric binary in $BUILD_DIR/stage0-publish"
  fi

  ok "Stage 0 complete — $STAGE0_BIN"
}

# ---------------------------------------------------------------------------
# Stage 1 — compile the Lyric compiler using the F# bootstrap (stage 0)
# ---------------------------------------------------------------------------
stage1() {
  info "Stage 1: compiling Lyric compiler packages with stage-0 lyric"
  mkdir -p "$STAGE1_DIR"

  # Helper to invoke stage-0, handling both native binaries and DLL wrappers.
  # On Windows the published output is a DLL; use dotnet directly.
  invoke_stage0() {
    if [[ "$STAGE0_BIN" == *.dll ]]; then
      dotnet "$STAGE0_BIN" "$@"
    else
      "$STAGE0_BIN" "$@"
    fi
  }

  # Build the stdlib bundle first (multi-package manifest).
  # Track A A1.4: the F# user-facing `lyric build --manifest`
  # dispatcher is gone; stage 1 drives the multi-package compile
  # through the bootstrap-only `--internal-manifest-build` flag
  # which reads `lyric.toml` and feeds the package list straight
  # to `Emitter.emitProject`.
  info "  compiling stdlib bundle"
  invoke_stage0 --internal-manifest-build "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE1_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stdlib bundle build failed"

  if [[ "$SKIP_CLI_BUNDLE" != "1" ]]; then
    # Track A (A1.2) — precompile cli/ + the full Lyric.Cli dependency
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
# emitter's stdlib auto-resolve discovers the cli/ package's full transitive
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
// Importing Lyric.Cli forces the F# emitter to compile the cli/ package and
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
    invoke_stage0 --internal-build "$driver_dir/driver.l" -o "$driver_out" \
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

  # `Lyric.Jvm.Hosts` is gone — the JVM byte-writer and constant-pool helpers
  # are now pure-Lyric BCL externs in `lyric-compiler/jvm/_kernel/kernel.l`
  # (docs/23-fsharp-shim-elimination.md).  No F# shim is published or copied
  # into the stage-1 bundle.

  # `FSharp.Core.dll` and `Lyric.Emitter.dll` are no longer bundled.
  # All stdlib kernel modules (`console_host.l`, `process_capture_host.l`,
  # `verifier_env_host.l`, `http_host.l`) migrated off `Lyric.Emitter.*`
  # host shims to direct BCL externs (#1489, #1493, G12, #1576).
  # No Lyric-compiled DLL in stage1 carries an AssemblyRef to either
  # `Lyric.Emitter` or `FSharp.Core` (verified by strings scan of stage1 DLLs).
  # The `Lyric.Cli.Aot` csproj no longer references `FSharp.Core.dll` explicitly.

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


  # `Lyric.Jobs.Host` is gone — the in-process scheduler helpers are now
  # pure-Lyric BCL externs in `lyric-jobs/src/_kernel/net/jobs_kernel.l`
  # (docs/23-fsharp-shim-elimination.md).  No F# shim is published or copied.

  # `Lyric.Mail.Host` is gone — the lyric-mail SMTP backend now binds
  # `System.Net.Mail` directly from its kernel.  No F# host shim is
  # published or copied into the stage-1 bundle.

  # `Lyric.Mq.Host` is gone — the in-memory queue helpers are now
  # pure-Lyric BCL externs in `lyric-mq/src/_kernel/net/mq_kernel.l`
  # (docs/23-fsharp-shim-elimination.md).  No F# shim is published or copied.

  # `Lyric.Web.Host` is gone — the HTTP listener path-finder is now
  # pure-Lyric BCL externs in `lyric-web/src/_kernel/net/web_kernel.l`
  # and `lyric-web/src/web.l` (docs/23-fsharp-shim-elimination.md).
  # No F# shim is published or copied.

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
# Precisely normalize the INTRINSIC IDENTITY fields of two .NET PE/ECMA-335
# images before byte-comparing them, by parsing the PE + metadata layout
# rather than guessing at "16-byte differing runs".  This avoids the
# false-positive failure mode of a heuristic mask (a run can split when two
# random GUIDs coincidentally share a byte) AND the false-negative risk of
# masking a real diff that merely happens to be 16 bytes long.
#
# Fields zeroed (located, not guessed):
#   * PE COFF TimeDateStamp (4 bytes in the COFF file header).
#   * PE optional-header CheckSum (4 bytes).
#   * The Module MVID — the first 16-byte GUID in the #GUID metadata heap,
#     reached via the CLI header -> metadata root -> stream table.
#
# Everything else is compared byte-for-byte.  In particular a genuine
# nondeterminism such as the F# stage-0 emitter's `build_date` wall-clock
# (embedded in the `Lyric.SdkVersion` resource of the bundle) is NOT masked
# and will surface as a real difference — which is the intended behaviour for
# this informational stage-0 diagnostic.
from pathlib import Path
import sys

def u16(b, o): return int.from_bytes(b[o:o+2], 'little')
def u32(b, o): return int.from_bytes(b[o:o+4], 'little')

def identity_regions(b):
    """Return [(offset, length), ...] for TimeDateStamp, CheckSum, MVID."""
    regions = []
    if b[0:2] != b'MZ':
        return regions
    pe = u32(b, 0x3c)
    if b[pe:pe+4] != b'PE\x00\x00':
        return regions
    coff = pe + 4
    # COFF header: Machine[2], NumberOfSections[2], TimeDateStamp[4], ...
    regions.append((coff + 4, 4))                 # COFF TimeDateStamp
    num_sections = u16(b, coff + 2)
    opt_size = u16(b, coff + 16)
    opt = coff + 20
    magic = u16(b, opt)
    regions.append((opt + 64, 4))                 # optional-header CheckSum
    # Data directories: PE32 -> dirs at opt+96, PE32+ -> dirs at opt+112.
    dd = opt + (96 if magic == 0x10b else 112)
    cli_rva = u32(b, dd + 14 * 8)                  # data dir 14 = CLI header
    if cli_rva == 0:
        return regions
    sections = opt + opt_size
    def rva_to_off(rva):
        for i in range(num_sections):
            s = sections + i * 40
            va = u32(b, s + 12)
            vsz = u32(b, s + 8)
            rawsz = u32(b, s + 16)
            raw = u32(b, s + 20)
            if va <= rva < va + max(vsz, rawsz):
                return raw + (rva - va)
        return None
    cli = rva_to_off(cli_rva)
    if cli is None:
        return regions
    md = rva_to_off(u32(b, cli + 8))              # CLI header -> Metadata RVA
    if md is None or b[md:md+4] != b'BSJB':
        return regions
    ver_len = u32(b, md + 12)
    p = md + 16 + ((ver_len + 3) // 4 * 4)
    p += 2                                         # flags
    n_streams = u16(b, p); p += 2
    for _ in range(n_streams):
        s_off = u32(b, p); p += 4
        u32(b, p); p += 4                          # stream size (unused)
        name_start = p
        while b[p] != 0:
            p += 1
        name = b[name_start:p]
        p += 1
        while (p - name_start) % 4 != 0:           # pad name to 4-byte boundary
            p += 1
        if name == b'#GUID':
            # The module Mvid is GUID index 1 = the first 16 bytes of the heap.
            regions.append((md + s_off, 16))
            break
    return regions

f1_path = Path(sys.argv[1]); f2_path = Path(sys.argv[2])
f1 = bytearray(f1_path.read_bytes())
f2 = bytearray(f2_path.read_bytes())
if len(f1) != len(f2):
    print(f"[compare_dlls] size mismatch: {len(f1)} vs {len(f2)} bytes in {f1_path.name}", file=sys.stderr)
    sys.exit(1)

for buf in (f1, f2):
    for off, length in identity_regions(buf):
        for i in range(off, off + length):
            if 0 <= i < len(buf):
                buf[i] = 0

if f1 != f2:
    sys.exit(1)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Stage 2 (a) — trust-anchor reproducibility gate (STRICT)
#
# Build two corpora TWICE through the self-hosted MSIL backend and assert each
# is byte-for-byte identical: (i) the full stdlib bundle, and (ii) the WHOLE
# Lyric.Cli compiler closure (every Lyric.* / Msil.* / Jvm.* package + its
# stdlib import closure).  This is the property a signed, reproducible release
# depends on (Q-dist-001).  The self-hosted emitter is deterministic by
# construction, so this passes with an exact `cmp` — no normalization — and a
# regression FAILS the build.
# ---------------------------------------------------------------------------
verify_selfhosted_reproducible() {
  info "Stage 2 (a): self-hosted reproducibility gate (STRICT)"

  # The AOT entry-point binary routes `--target dotnet` through the self-hosted
  # Msil.Bridge.  It embeds the stage-1 DLLs at C#-build time, so rebuild it
  # (clean) now that stage 1 has just produced fresh outputs.
  # Honour $BUILD_CONFIG (CI's convention) so the binary path matches however
  # the AOT project was configured; default to Release for standalone runs
  # (stage 0 publishes Release).
  local build_config="${BUILD_CONFIG:-Release}"
  local aot_proj="$COMPILER_DIR/src/Lyric.Cli.Aot"
  local aot_bin="$aot_proj/bin/$build_config/net10.0/lyric"
  info "  building AOT entry-point (Lyric.Cli.Aot, $build_config) against the fresh stage-1 DLLs"
  dotnet build "$aot_proj" --configuration "$build_config" --no-incremental \
    > "$BUILD_DIR/aot-build.log" 2>&1 || \
    die "AOT entry-point build failed (see $BUILD_DIR/aot-build.log)"
  [[ -x "$aot_bin" ]] || die "AOT lyric binary not found at $aot_bin after build"

  # (i) Stdlib bundle: build lyric.full.toml twice; the single output must be
  # byte-identical.
  "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    manifest "$aot_bin" "$STDLIB_DIR/lyric.full.toml" || \
    die "self-hosted reproducibility gate FAILED — the stdlib bundle is not byte-stable"

  # (ii) Whole compiler: self-host-compile the entire Lyric.Cli closure twice;
  # every emitted DLL must be byte-identical.  This extends the reproducible
  # corpus from the stdlib to the entire self-hosted compiler.
  "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    closure "$aot_bin" || \
    die "self-hosted reproducibility gate FAILED — the compiler closure is not byte-stable"

  ok "Self-hosted emit is byte-for-byte reproducible (trust-anchor gate passed)"
}

# ---------------------------------------------------------------------------
# Stage 2 (b) — stage-0 reproducibility diagnostic (INFORMATIONAL)
#
# Reproduce the F# stage-0 CLI-bundle precompile and compare the stage-1 and
# stage-2 DLLs after precisely normalizing the intrinsic identity fields (MVID,
# PE timestamp, checksum).  The F# emitter is non-reproducible by design (it
# bakes a `build_date` wall-clock into the bundle's `Lyric.SdkVersion`) and is
# frozen on a deletion schedule, so this is reported but NEVER fatal — it
# tracks stage-0 drift until the F# path is deleted.
# ---------------------------------------------------------------------------
stage2() {
  if [[ "$SKIP_VERIFY" == "1" ]]; then
    info "SKIP_VERIFY=1; skipping all stage-2 reproducibility verification"
    return 0
  fi

  # (a) The real gate: the self-hosted emitter must be byte-stable.
  verify_selfhosted_reproducible

  # (b) Informational stage-0 diagnostic.
  info "Stage 2 (b): stage-0 (F#) reproducibility diagnostic (informational)"

  mkdir -p "$STAGE2_DIR"

  # First, compile the stdlib bundle via the F# stage-0 path so we
  # produce the top-level Lyric.Stdlib.dll the stage-1 bundle contains.
  info "  compiling stdlib bundle (F# stage-0 path)"
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$STAGE0_BIN" --internal-manifest-build "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE2_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stage-2 stdlib bundle build failed"

  # Re-run the same CLI-bundle precompile the stage-1 step used (identical
  # driver, including the direct Std.Testing.Mocking import) so the two bundles
  # contain exactly the same set of DLLs and the comparison is apples-to-apples.
  local driver_dir="$BUILD_DIR/stage2-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the stage-2 CLI-bundle precompile.
// Mirrors the stage-1 driver exactly (same import closure) so the stage-1 vs
// stage-2 DLL sets line up one-to-one.
package Lyric.CliBundleStage2
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
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

  # `FSharp.Core.dll` and `Lyric.Emitter.dll` are no longer bundled —
  # see stage-1 comment above.  Stage-2 mirrors stage-1 for a fair comparison.

  # Lyric.Session.Host is gone — see stage-1 comment above (#1777).
  # Lyric.Jobs.Host is gone — see stage-1 comment above.
  # Lyric.Mq.Host is gone — see stage-1 comment above.
  # Lyric.Web.Host is gone — see stage-1 comment above.

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
  # Compare stage-1 and stage-2 outputs file-by-file (informational).
  # Intrinsic identity fields (MVID, PE timestamp, checksum) are precisely
  # normalized; a genuine nondeterminism such as the F# `build_date` wall-clock
  # is NOT masked and surfaces as a real DIFF.
  # -------------------------------------------------------------------------
  info "  comparing stage-1 vs stage-2 F# bundle outputs (identity fields normalized)"
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
      echo "  DIFF:    $name (stage-1 vs stage-2 differ after normalizing identity fields)" >&2
      diffs=$((diffs + 1))
    else
      echo "  MATCH:   $name"
    fi
  done
  # Reverse check: flag DLLs present in stage-2 but absent from stage-1.
  # Such extra assemblies indicate an unexpected build artefact or a package
  # name change between stages.
  for f in "$STAGE2_DIR"/*.dll; do
    local name
    name="$(basename "$f")"
    if [[ ! -f "$STAGE1_DIR/$name" ]]; then
      echo "  EXTRA:   $name (stage-2 only — not present in stage-1)" >&2
      diffs=$((diffs + 1))
    fi
  done
  shopt -u nullglob

  if [[ $diffs -eq 0 ]]; then
    ok "Stage-0 diagnostic: all F# bundle DLLs match (modulo intrinsic identity fields)"
  else
    # NEVER fatal: the F# stage-0 emitter is non-reproducible by design (it
    # embeds a `build_date` wall-clock in `Lyric.SdkVersion`) and is frozen on
    # a deletion schedule.  The STRICT gate is the self-hosted check in (a).
    info "  stage-0 diagnostic: $diffs F# bundle DLL(s) differ (expected — see Lyric.Stdlib.dll build_date)"
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
