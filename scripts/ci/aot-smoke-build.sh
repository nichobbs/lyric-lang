#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; AOT smoke test cannot run"
  exit 1
fi
dotnet build bootstrap/src/Lyric.Cli.Aot --configuration $BUILD_CONFIG
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT entry-point binary not found at $lyric_bin"
  exit 1
fi
# Stage the stdlib packages the F# stage-0 emitter cannot build
# (#2592: Std.Sort et al.) into the toolchain lib dir(s) via the
# self-hosted emitter, so user programs importing them resolve at
# run time.  Runs once after the AOT build; later steps in this job
# reuse the populated lib dir.
bash scripts/stage-selfhosted-stdlib.sh "$lyric_bin" "$(dirname "$lyric_bin")" .bootstrap/stage1
# Post-collapse (D111) every Std.* reference resolves to the single
# Lyric.Stdlib bundle deployed above, so the per-package userlib/ stdlib
# staging is no longer needed (and would shadow the bundle via
# copyRuntimeDepsBeside) — removed.
# #6503: single-file builds inside the workspace now resolve
# imports of workspace members against ALREADY-BUILT member DLLs
# (and fail loudly on unbuilt ones).  examples/docker_client.l
# imports Lyric.Docker, so build that member first — this also
# upgrades the example from leniently-compiled (runtime-invalid,
# the pre-#6503 state) to genuinely type-checked against the
# real library.
"$lyric_bin" build --manifest lyric-docker/lyric.toml
for ex in examples/*.l; do
  # `@proof_required` files are verifier-only — they have no
  # `func main` so `lyric build` doesn't apply.  The AOT
  # binary's `lyric prove` path needs `Lyric.Emitter.dll`
  # in its resolution context (the F# emitter is what
  # `Std.VerifierEnvHost.hostGetEnv` chains through); the
  # AOT csproj doesn't carry the F# emitter today, so skip
  # them for now.  Tracked as a follow-up to Track A.
  if head -n 1 "$ex" | grep -q '^@proof_required'; then
    echo "=== skip proof-only $ex (AOT prove path: follow-up) ==="
    continue
  fi
  echo "=== build $ex ==="
  out="/tmp/$(basename "$ex" .l).dll"
  "$lyric_bin" build "$ex" -o "$out" --force
done

