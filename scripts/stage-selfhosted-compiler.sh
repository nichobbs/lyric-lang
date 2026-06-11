#!/usr/bin/env bash
# stage-selfhosted-compiler.sh — stage the self-hosted-emitted per-package
# compiler DLLs under <lib-dir>/selfhosted so native `lyric test` links them
# as restored deps instead of the F#-emitted stage-1 bundle DLLs (#3086).
#
# Why this exists: the stage-1 compiler DLLs beside the AOT binary are emitted
# by the F# stage-0 `--internal-build`, whose contract-metadata writer has no
# `IVal` arm — module-level `pub val` constants (e.g. `Msil.Tables`' MDA_* /
# TDF_* flag values) are silently absent from the embedded `Lyric.Contract`
# resource.  A `@test_module` that links such a package as a restored dep then
# fails with T0020 "unknown name".  The self-hosted contract writer emits the
# vals, so `Emitter.compilerClosureDllPaths` prefers a complete self-hosted
# closure under `<lib-dir>/selfhosted/` when one is staged.
#
# The staged set is the whole `Lyric.Cli` import closure — every Lyric.* /
# Msil.* / Jvm.* compiler package plus the stdlib packages they pull in —
# produced by one `--internal-perpackage-build` run (the same emit CI's
# "Whole compiler self-host-compiles" gate validates).  Staging into a
# dedicated `selfhosted/` subdirectory deliberately leaves the F#-emitted
# DLLs beside the AOT binary untouched: those remain the toolchain's own
# runtime until the self-hosted-built-toolchain switch (docs/23).
#
# Usage: stage-selfhosted-compiler.sh <lyric-binary> <lib-dir> [<lib-dir> ...]
set -euo pipefail

LYRIC_BIN="${1:?usage: stage-selfhosted-compiler.sh <lyric-binary> <lib-dir>...}"
shift
LIB_DIRS=("$@")
if [[ ${#LIB_DIRS[@]} -eq 0 ]]; then
  echo "stage-selfhosted-compiler: no target lib dirs given" >&2
  exit 1
fi

emit_dir="$(mktemp -d)"
trap 'rm -rf "$emit_dir"' EXIT

driver="$emit_dir/driver.l"
cat > "$driver" <<'EOF'
// Auto-generated driver for the self-hosted compiler-DLL staging step.
// Importing Lyric.Cli makes emitPerPackageClosure discover and emit the
// whole compiler-package closure (plus its stdlib import closure).
package SelfHostedCompilerStage
import Lyric.Cli
func main(): Unit { }
EOF

out="$emit_dir/out"
if ! "$LYRIC_BIN" --internal-perpackage-build "$driver" "$out" 2>&1; then
  echo "stage-selfhosted-compiler: --internal-perpackage-build failed (see above)." >&2
  exit 1
fi

# Sanity: the closure must include the CLI itself and both backends.
for dll in Lyric.Lyric.Cli.dll Lyric.Msil.Codegen.dll Lyric.Jvm.Codegen.dll; do
  if [[ ! -f "$out/$dll" ]]; then
    echo "stage-selfhosted-compiler: expected $dll missing from the emit output" >&2
    exit 1
  fi
done

staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  mkdir -p "$dir/selfhosted"
  for dll in "$out"/*.dll; do
    cp -f "$dll" "$dir/selfhosted/"
    staged=$((staged + 1))
  done
done

echo "stage-selfhosted-compiler: staged $staged DLL(s) into ${#LIB_DIRS[@]} selfhosted dir(s)"
