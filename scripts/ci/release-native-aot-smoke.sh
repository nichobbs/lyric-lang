#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; native AOT smoke test cannot run"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
dir="$(mktemp -d)"
src="$dir/hello.l"
# Also asserts the well-known `build_profile` define (docs/60 M1h,
# #5852): a real --release --aot build injects build_profile=release into
# the staging compile, so BuildInfo.profile reports "release" in the
# native binary. This is the load-bearing guard for the release-path
# injection, and this job (unlike `build`) has clang/ILCompiler.
cat > "$src" <<'LYRIC'
package Hello
import Std.Core
import Std.BuildInfo
func main(): Int {
  println("hello-aot")
  println("profile=" + buildInfo().profile)
  0
}
LYRIC
native_bin="$dir/hello"
"$lyric_bin" build --release --aot "$src" -o "$native_bin"
if [ ! -x "$native_bin" ]; then
  echo "::error::native binary not produced at $native_bin"
  exit 1
fi
out="$("$native_bin" 2>&1)"
echo "native AOT output: $out"
echo "$out" | grep -qx "hello-aot" || { echo "::error::native AOT smoke test did not print hello-aot; got: '$out'"; exit 1; }
echo "$out" | grep -qx "profile=release" || { echo "::error::--release --aot build did not inject build_profile=release (#5852 M1h); got: '$out'"; exit 1; }
echo "OK: native AOT binary produced and executed correctly (hello-aot + build_profile=release)." >> "$GITHUB_STEP_SUMMARY"

# Regression guard for #7514: `./bin/lyric test --manifest <multi-package
# manifest with a path dependency>` was reported to fail with T0010/T0020
# through the AOT entry-point binary while the managed `dotnet lyric.dll`
# entry point passed the same suite. The two entry points share the exact
# same compiled DLLs and path-discovery code, so nothing here distinguishes
# them beyond the launcher — but this job's `lyric-test-setup` composite
# action unconditionally overwrites the downloaded $lyric_bin artifact with
# a `dotnet lyric.dll` shell wrapper (scripts/ci/write-lyric-dotnet-wrapper.sh,
# #7025), so by this point in the job $lyric_bin is NOT the real apphost —
# running the guard against it as-is would silently exercise the exact
# `dotnet lyric.dll` path the issue says already passes, proving nothing.
# Rebuild it: `dotnet build` of an exe project always regenerates a genuine
# native apphost stub (this is exactly what `make lyric`'s `aot` target and
# a developer's `./bin/lyric` are), overwriting the wrapper script in place.
# The stage-1 DLLs this job already has (checked above) make this a
# ~1-2s relink, no NuGet/ILCompiler work.
dotnet build bootstrap/src/Lyric.Cli.Aot --configuration "$BUILD_CONFIG" --no-incremental
if head -c 2 "$lyric_bin" | grep -q '#!'; then
  echo "::error::$lyric_bin is still a shell wrapper after rebuild; #7514 regression guard would not exercise the real AOT apphost"
  exit 1
fi
for manifest in lyric-jsonrpc/lyric.toml lyric-mcp/lyric.toml; do
  echo "=== real AOT apphost: lyric test --manifest $manifest ==="
  if ! "$lyric_bin" test --manifest "$manifest"; then
    echo "::error::#7514 regression: '$lyric_bin test --manifest $manifest' failed through the real AOT apphost entry point"
    exit 1
  fi
done
echo "OK: real AOT apphost (not the dotnet-lyric.dll wrapper) ran lyric-jsonrpc + lyric-mcp (path-dependency manifest) tests cleanly (#7514 regression guard)." >> "$GITHUB_STEP_SUMMARY"

