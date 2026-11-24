#!/usr/bin/env bash
# SPIKE (docs/73 S0 spike a), not shipped. Overlays the spike's `Std.SpikeServer` (shared) and
# `Std.SpikeServerHost` (three kernel twins) onto a copy of lyric-stdlib/std through LYRIC_STD_PATH, so no
# stdlib file in the tree changes, then builds and runs driver.l on dotnet, the JVM and native and builds the
# per-package outputs (`--internal-perpackage-build`) that the stdlib bundle build uses.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
LYRIC="${LYRIC:-./bin/lyric}"
OUT="${OUT:-$(mktemp -d)}"
SPIKE=benchmarks/http_server/spikes/split
mkdir -p "$OUT/overlay"
cp -r lyric-stdlib/std "$OUT/overlay/std"
cp -r "$SPIKE"/std/. "$OUT/overlay/std/"
export LYRIC_STD_PATH="$OUT/overlay/std"
rc=0
for t in jvm native; do
  case $t in jvm) o="$OUT/driver.jar"; run=(java -jar "$o");; native) o="$OUT/driver-native"; run=("$o");; esac
  echo "== build --target $t (the stdlib source loader picks the overlay up)"
  if "$LYRIC" build --target "$t" "$SPIKE/driver.l" -o "$o" > "$OUT/build-$t.log" 2>&1; then
    echo "   built; running"
    timeout 60 "${run[@]}" 2>&1 | tail -1 | sed "s/^/   [$t] /"
  else
    echo "   BUILD FAILED, first errors:"; grep -m5 -E "error|Error" "$OUT/build-$t.log" | sed "s/^/   [$t] /"; rc=1
  fi
done

# dotnet links against the compiled stdlib bundle, whose package list is lyric.full.toml: the new packages
# are registered there (in the overlay copy) and the bundle is rebuilt; `--internal-perpackage-build` then
# emits them as per-package assemblies, as the stdlib build does for the HTTP packages.
echo "== dotnet: bundle with the spike packages registered in lyric.full.toml"
mkdir -p "$OUT/bundle" "$OUT/dotnet"
cp -r lyric-stdlib "$OUT/bundle/lyric-stdlib"
cp -r "$SPIKE"/std/. "$OUT/bundle/lyric-stdlib/std/"
python3 -I - "$OUT/bundle/lyric-stdlib/lyric.full.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '"Std.HttpServer"       = "std/_kernel/http_server.l"\n'
assert anchor in s
s = s.replace(anchor, anchor + '"Std.SpikeServerHost" = "std/_kernel/spike_server_host.l"\n"Std.SpikeServer" = "std/spike_server.l"\n')
open(p, "w").write(s)
PY
( cd "$OUT/bundle/lyric-stdlib" && "$LYRIC" build --manifest lyric.full.toml --no-restore -o "$OUT/bundle/Lyric.Stdlib.dll" > "$OUT/build-bundle.log" 2>&1 ) \
  && "$LYRIC" build --target dotnet "$SPIKE/driver.l" -o "$OUT/dotnet/driver.dll" > "$OUT/build-dotnet.log" 2>&1 \
  && cp "$OUT/bundle/Lyric.Stdlib.dll" "$OUT/dotnet/Lyric.Stdlib.dll" \
  && { echo "   built; running"; timeout 60 dotnet "$OUT/dotnet/driver.dll" 2>&1 | tail -1 | sed "s/^/   [dotnet] /"; } \
  || { echo "   FAILED"; tail -5 "$OUT/build-bundle.log" "$OUT/build-dotnet.log"; rc=1; }
echo "== per-package build (dotnet; the JVM toolchain bundles one JAR, there is no per-package emit)"
mkdir -p "$OUT/pp-dotnet"
if "$LYRIC" --internal-perpackage-build "$SPIKE/driver.l" "$OUT/pp-dotnet" > "$OUT/pp-dotnet.log" 2>&1; then
  ls "$OUT/pp-dotnet" | grep -i -E "SpikeServer" | sed "s/^/   [dotnet] /"
else
  echo "   FAILED"; grep -m5 -E "error|Error" "$OUT/pp-dotnet.log" | sed "s/^/   [dotnet] /"; rc=1
fi

# The source loaders merge same-package files from the stdlib's top-level directory and from the target kernel
# directories; only a `_kernel_jvm/<name>.l` or `_kernel_native/<name>.l` shadows a `_kernel/<name>.l` of the
# same basename, never a top-level `std/<name>.l`. So a shared `std/spike_server.l` plus a per-target file of the
# same package and the same names is a duplicate declaration. This is why the plan's shared driver cannot sit at
# `std/http_server.l` while `_kernel_jvm/http_server.l` and `_kernel_native/http_server.l` still exist.
echo "== loader shadowing check: a same-basename per-target file next to a top-level shared file"
mkdir -p "$OUT/dup"
cp -r "$OUT/overlay/std" "$OUT/dup/std"
printf 'package Std.SpikeServer\n\npub func spikePort(q: in Int): Int {\n  q\n}\n' > "$OUT/dup/std/_kernel_jvm/spike_server.l"
cp "$OUT/dup/std/_kernel_jvm/spike_server.l" "$OUT/dup/std/_kernel_native/spike_server.l"
for t in jvm native; do
  if LYRIC_STD_PATH="$OUT/dup/std" "$LYRIC" build --target "$t" "$SPIKE/driver.l" -o "$OUT/dup/d-$t" > "$OUT/dup/$t.log" 2>&1; then
    echo "   [$t] built (the per-target file shadowed the shared one)"
  else
    echo "   [$t] does not build, as expected: $(grep -m1 -E 'error' "$OUT/dup/$t.log" | cut -c1-140)"
  fi
done
echo "outputs in $OUT"
exit $rc
