#!/usr/bin/env bash
# `lyric prove` on a package of several files (#8108): a `Result`/`Option`
# type a sibling file declares is not the standard library's, in both the
# single-file and the --manifest mode — whichever file of the package's
# build set declares it — while an unrelated sibling type leaves the
# standard library's modelled.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/prove-package-scope.sh
set -euo pipefail
lyric_bin="${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
root="$(cd "$(dirname "$0")/../.." && pwd)/examples/prove-package-scope"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# `rejected` also requires the V0033 that says the sibling's type is not
# modelled as the standard library's, not just a failing exit.
expect() {
  local want="$1" label="$2"; shift 2
  local rc=0
  "$@" > "$log" 2>&1 || rc=$?
  if [ "$want" = proved ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $label: expected the proof to go through"; cat "$log"; exit 1
  fi
  if [ "$want" = rejected ]; then
    if [ "$rc" -eq 0 ] || ! grep -q "V0033 error .*a value the verifier does not model (sort field.isSome)" "$log"; then
      echo "FAIL: $label: expected V0033 for the sibling's Option"; cat "$log"; exit 1
    fi
  fi
  echo "PASS: $label"
}

# shadow: a sibling in the same directory; nested: in a subdirectory of the
# package directory; otherpkg: a file of the entry with another `package`
# line; filelist: an explicit file list across directories.
for case in shadow:src/p/b_logic.l nested:src/p/b_logic.l otherpkg:src/p/b_logic.l filelist:src/y/b_logic.l; do
  dir="${case%%:*}"
  file="${case#*:}"
  expect rejected "$dir, single file" "$lyric_bin" prove "$root/$dir/$file"
  expect rejected "$dir, --manifest" "$lyric_bin" prove --manifest "$root/$dir/lyric.toml"
done
# nestedmanifest: the package directory holds a project of its own, which
# the outer build still merges; found through the outer ancestor manifest.
expect rejected "nestedmanifest, single file" "$lyric_bin" prove "$root/nestedmanifest/src/p/inner/b_logic.l"
expect rejected "nestedmanifest, --manifest" "$lyric_bin" prove --manifest "$root/nestedmanifest/lyric.toml"
# outoftree: the manifest lists a file outside its own tree.  A single-file
# proof of that file cannot find the manifest (documented); --manifest sees
# the package and warns about the file.
expect rejected "outoftree, --manifest" "$lyric_bin" prove --manifest "$root/outoftree/proj/lyric.toml"
if ! grep -q "prove: warning: package 'P' lists .*shared/b_logic.l, outside" "$log"; then
  echo "FAIL: outoftree, --manifest: expected the outside-the-tree warning"; cat "$log"; exit 1
fi
echo "PASS: outoftree, --manifest warning"
expect proved "control, single file" "$lyric_bin" prove "$root/control/src/p/b_logic.l"
expect proved "control, --manifest" "$lyric_bin" prove --manifest "$root/control/lyric.toml"
