#!/usr/bin/env bash
# stage-selfhosted-compiler.sh — stage the self-hosted-emitted compiler as a
# SINGLE `Lyric.Compiler.dll` bundle under <lib-dir>/selfhosted so native
# `lyric test` links it as one restored dep (D111).
#
# Why a single bundle (not per-package): the self-hosted emitter's per-package
# cross-package emission is not execution-clean (docs/41 §R7) — types defined in
# one compiler package and referenced from another corrupt across the assembly
# boundary, so a self-hosted-emitted parser mis-parses even `package P`.
# Bundling the whole `Lyric.Cli` import closure into ONE assembly makes every
# cross-package reference in-bundle (internal), sidestepping the corruption.
# The bundle also carries each package's `pub val` constants in its
# `Lyric.Contract.<Pkg>` metadata (the original #3086 reason this staging
# exists — the retired F# writer dropped them).
#
# `loadRestoredPackage` yields one artifact per `Lyric.Contract.<Pkg>` resource
# from the single DLL, and `assemblySimpleNameFromDll` derives every AssemblyRef
# from the bundle's file stem (`Lyric.Compiler`), so a consumer self-test
# resolves a self-consistent compiler from the one file.
# `Emitter.compilerClosureDllPaths` prefers `<lib-dir>/selfhosted/Lyric.Compiler.dll`
# when present.
#
# Staging into a dedicated `selfhosted/` subdirectory deliberately leaves the
# stage-1 DLLs beside the AOT binary untouched (the toolchain's own runtime).
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
// Auto-generated driver for the self-hosted compiler-bundle staging step.
// Importing Lyric.Cli makes emitCompilerBundle discover and emit the whole
// compiler-package closure as one Lyric.Compiler.dll (Std.* referenced
// externally as Lyric.Stdlib).
package SelfHostedCompilerStage
import Lyric.Cli
func main(): Unit { }
EOF

bundle="$emit_dir/Lyric.Compiler.dll"
if ! "$LYRIC_BIN" --internal-compiler-bundle-build "$driver" "$bundle" 2>&1; then
  echo "stage-selfhosted-compiler: --internal-compiler-bundle-build failed (see above)." >&2
  exit 1
fi
if [[ ! -f "$bundle" ]]; then
  echo "stage-selfhosted-compiler: Lyric.Compiler.dll not produced" >&2
  exit 1
fi

# Content check (#4043): the old per-package staging asserted the CLI and both
# backends emitted as their own DLLs.  The single bundle has no per-package
# files, so verify instead that it carries the embedded `Lyric.Contract.<Pkg>`
# metadata resource for each — a dropped import path (e.g. a missing JVM-backend
# edge) would otherwise yield a bundle that links but silently lacks a backend.
for pkg in Lyric.Cli Msil.Codegen Jvm.Codegen; do
  if ! strings -n 8 "$bundle" | grep -q "Lyric.Contract.$pkg"; then
    echo "stage-selfhosted-compiler: bundle is missing the Lyric.Contract.$pkg resource (malformed emit?)" >&2
    exit 1
  fi
done

staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  mkdir -p "$dir/selfhosted"
  cp -f "$bundle" "$dir/selfhosted/"
  staged=$((staged + 1))
done

echo "stage-selfhosted-compiler: staged Lyric.Compiler.dll into $staged selfhosted dir(s)"
