#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generic-opaque-restored-e2e.sh: a generic opaque type from a separately
# built dependency (#8187).  A library declares `opaque type Opq[T]`, a
# constructor returning `Opq[Int]`, a generic reader `Opq.get[T]` and a
# non-generic wrapper `getInt`.  Built on its own and restored by an
# application (`--target dotnet`):
#   - the application builds an `Opq[Int]` through the library and reads it
#     through the wrapper: it builds and prints 3;
#   - the application calling the generic `get` itself would specialise a body
#     that reads the type's internal field, which the build rejects as T0165;
#   - the same two packages in one project share an assembly, so the direct
#     call builds and prints 3.
#
#   bash scripts/ci/generic-opaque-restored-e2e.sh
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/src" "$work/app/src"

cat > "$work/lib/lyric.toml" <<'TOML'
[package]
name = "Og.Lib"
version = "0.1.0"
[project]
name = "Og.Lib"
output = "single"
output_assembly = "OgLib.dll"
[project.packages]
"OgLib" = "src/lib.l"
TOML
cat > "$work/lib/src/lib.l" <<'EOF'
package OgLib

pub opaque type Opq[T] {
  v: T
}

pub func Opq.get[T](self: in Opq[T]): T = self.v

pub func mk(x: in Int): Opq[Int] = Opq(v = x)

pub func getInt(o: in Opq[Int]): Int = o.get()
EOF
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "Og.App"
version = "0.1.0"
[project]
name = "Og.App"
output = "single"
output_assembly = "OgApp.dll"
[project.packages]
"OgApp" = "src/app.l"
[dependencies]
"Og.Lib" = { path = "../lib" }
TOML

fail=0
if ! "$lyric_bin" build --manifest "$work/lib/lyric.toml" >"$work/lib.log" 2>&1; then
  echo "FAIL: the library did not build"; cat "$work/lib.log"; exit 1
fi

cat > "$work/app/src/app.l" <<'EOF'
package OgApp

import OgLib

func main(): Int {
  println(toString(getInt(mk(3))))
  0
}
EOF
out="$("$lyric_bin" run --manifest "$work/app/lyric.toml" 2>&1)"
if [ "$(echo "$out" | tail -1)" != "3" ]; then
  echo "FAIL: restored generic opaque through the wrapper: expected 3, got:"; echo "$out"; fail=1
fi

cat > "$work/app/src/app.l" <<'EOF'
package OgApp

import OgLib

func main(): Int {
  println(toString(mk(3).get()))
  0
}
EOF
out="$("$lyric_bin" build --manifest "$work/app/lyric.toml" 2>&1)"
if ! echo "$out" | grep -q 'error\[T0165\]'; then
  echo "FAIL: a specialisation reading the restored opaque type's field: expected T0165, got:"; echo "$out"; fail=1
fi

# The same two packages in ONE project share an assembly, so a specialisation
# in the application of the library's generic function reads the field.
mkdir -p "$work/bundle/src"
cat > "$work/bundle/lyric.toml" <<'TOML'
[package]
name = "Og.B"
version = "0.1.0"
[project]
name = "Og.B"
[project.packages]
"OgLib" = "src/lib.l"
"OgApp" = "src/app.l"
TOML
cp "$work/lib/src/lib.l" "$work/bundle/src/lib.l"
cp "$work/app/src/app.l" "$work/bundle/src/app.l"
out="$("$lyric_bin" run --manifest "$work/bundle/lyric.toml" 2>&1)"
if [ "$(echo "$out" | tail -1)" != "3" ]; then
  echo "FAIL: generic opaque type across packages of one project: expected 3, got:"; echo "$out"; fail=1
fi

[ "$fail" -eq 0 ] && echo "generic opaque types from a restored dependency: ok"
exit "$fail"
