#!/usr/bin/env bash
# stage-userlib-stdlib.sh — stage a self-hosted-emitted (arity-suffixed) copy of
# the full standard library under `<lib-dir>/userlib/` for USER-CODE linking.
#
# Why this exists: in a mint-bootstrapped toolchain the compiler's own runtime
# stdlib (the `Lyric.Stdlib.*.dll` beside the binary) is built by the stage-0
# emitter, which names generic stdlib types WITHOUT the CLR arity suffix
# (`Std.Core.Option`, `Std.Core.Option_Some`).  But the self-hosted codegen the
# compiler runs emits user code that REFERENCES those types WITH the suffix
# (`Option`1`, `Option_Some`1`), matching the in-bundle generic ABI (#2362).  So
# user code that constructs a stdlib generic case cross-package
# (`Some(x)` in package A, consumed by package B) faults at load time with
# `Could not load type 'Std.Core.Option`1'` when linked against the mint stdlib.
#
# The compiler can EMIT the stdlib with its own (suffixing) codegen, producing a
# stdlib whose names match the references user code carries.  We stage that
# suffixed stdlib under `<lib-dir>/userlib/`; `copyRuntimeDepsBeside`
# (Lyric.Cli) prefers it for user output while the compiler keeps its own
# non-suffixed stdlib for its process.  A fully self-hosted toolchain already
# ships a suffixed stdlib and does not need this (the consumer falls back to the
# main lib dir when `userlib/` is absent).
#
# Usage: stage-userlib-stdlib.sh <lyric-binary> <lib-dir> [<lib-dir> ...]
set -euo pipefail

LYRIC_BIN="${1:?usage: stage-userlib-stdlib.sh <lyric-binary> <lib-dir>...}"
shift
LIB_DIRS=("$@")
if [[ ${#LIB_DIRS[@]} -eq 0 ]]; then
  echo "stage-userlib-stdlib: no target lib dirs given" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STD_DIR="$REPO_ROOT/lyric-stdlib/std"

emit_dir="$(mktemp -d)"
trap 'rm -rf "$emit_dir"' EXIT

# Driver importing every public Std.* package (and the kernel-boundary packages)
# so the per-package emit produces the COMPLETE stdlib in one consistent,
# suffix-named build.  Completeness matters: `copyRuntimeDepsBeside` copies all
# `Lyric.Stdlib.*.dll` from `userlib/` (not the mint lib dir), so a missing
# package would surface as `Could not load file or assembly 'Lyric.Stdlib.X'`.
driver="$emit_dir/driver.l"
{
  echo "package UserlibStdlibStage"
  grep -rhoE '^package Std\.[A-Za-z.]+' "$STD_DIR"/*.l "$STD_DIR"/_kernel/*.l | sed 's/^package /import /' | sort -u
  echo "func main(): Unit { }"
} > "$driver"

out="$emit_dir/out"
rm -rf "$out"; mkdir -p "$out"
if ! "$LYRIC_BIN" --internal-perpackage-build "$driver" "$out" --target dotnet 2>&1; then
  echo "stage-userlib-stdlib: --internal-perpackage-build failed (see above)." >&2
  exit 1
fi

emitted="$(ls "$out"/Lyric.Stdlib.*.dll 2>/dev/null | wc -l)"
if [[ "$emitted" -eq 0 ]]; then
  echo "stage-userlib-stdlib: ERROR: no Lyric.Stdlib.*.dll emitted into $out." >&2
  exit 1
fi

staged_dirs=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  ul="$dir/userlib"
  mkdir -p "$ul"
  cp -f "$out"/Lyric.Stdlib.*.dll "$ul/"
  staged_dirs=$((staged_dirs + 1))
done

echo "stage-userlib-stdlib: staged $emitted suffixed stdlib DLL(s) into userlib/ under $staged_dirs lib dir(s)"
