#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# buildinfo-project-version-define.sh — BuildInfo well-known `version`
# auto-injection (docs/60 §9.2, #5852): a project build with
# `[package].version` in lyric.toml populates `BuildInfo.version` with NO
# `--define`; a `--define version=...`/`--define greeting=...` override
# takes precedence; the well-known `target` define auto-injects on both
# targets and is itself overridable; the well-known `build_profile` define
# defaults to `debug` and is overridable; docs/63 band B0 (#6279) profile/
# shape axis independence (`--release --shape portable`, bare `--release`
# no longer implying AOT, `--debug --shape portable`).
# Extracted from ci.yml's "BuildInfo project version + --define" step
# (#6387/check-workflow-size.sh — see scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found; skipping BuildInfo project version test"
  exit 1
fi
proj="$(mktemp -d)"
mkdir -p "$proj/src"
cat > "$proj/lyric.toml" <<'TOML'
[package]
name = "biverproj"
version = "4.5.6"

[project]
name = "biverproj"
output = "single"
output_assembly = "biverproj.dll"

[project.packages]
"biverproj" = "src/main.l"
TOML
cat > "$proj/src/main.l" <<'LYR'
package biverproj

import Std.Console
import Std.BuildInfo

@build_const("greeting")
val GREETING: String = "default-greeting"

func main(): Int {
  val bi = buildInfo()
  println("version=" + bi.version)
  println("greeting=" + GREETING)
  0
}
LYR
# (M1d) project build with NO --define: BuildInfo.version auto-injected
# from the manifest; @build_const keeps its in-source fallback.
echo "=== dotnet project build (manifest version=4.5.6, no --define) ==="
"$lyric_bin" build --manifest "$proj/lyric.toml"
out="$(dotnet "$proj/bin/biverproj.dll")"
echo "dotnet: $out"
echo "$out" | grep -qx "version=4.5.6"          || { echo "::error::dotnet project build did not auto-inject BuildInfo.version from the manifest"; exit 1; }
echo "$out" | grep -qx "greeting=default-greeting" || { echo "::error::@build_const fallback wrong on project build"; exit 1; }
echo "=== jvm project build (no --define) ==="
"$lyric_bin" build --manifest "$proj/lyric.toml" --target jvm -o "$proj/biverproj.jar"
outj="$(java -jar "$proj/biverproj.jar")"
echo "jvm: $outj"
echo "$outj" | grep -qx "version=4.5.6" || { echo "::error::jvm project build did not auto-inject BuildInfo.version from the manifest"; exit 1; }
# (phase C, #5852) project build WITH --define: user --define overrides
# the well-known manifest version, and substitutes the @build_const.
echo "=== dotnet project build WITH --define (override) ==="
"$lyric_bin" build --manifest "$proj/lyric.toml" --define version=9.9.9 --define greeting=hello-project
outd="$(dotnet "$proj/bin/biverproj.dll")"
echo "dotnet(--define): $outd"
echo "$outd" | grep -qx "version=9.9.9"        || { echo "::error::project --define version did not override the manifest well-known version"; exit 1; }
echo "$outd" | grep -qx "greeting=hello-project" || { echo "::error::project --define did not substitute the @build_const"; exit 1; }
echo "=== jvm project build WITH --define (override) ==="
"$lyric_bin" build --manifest "$proj/lyric.toml" --target jvm --define version=7.7.7 --define greeting=jvm-greet -o "$proj/biverproj.jar"
outjd="$(java -jar "$proj/biverproj.jar")"
echo "jvm(--define): $outjd"
echo "$outjd" | grep -qx "version=7.7.7"     || { echo "::error::jvm project --define version did not override the manifest version"; exit 1; }
echo "$outjd" | grep -qx "greeting=jvm-greet" || { echo "::error::jvm project --define did not substitute the @build_const"; exit 1; }
# (M1f, #5852) well-known `target` define auto-injected in pipeParseAndErase
# with NO --define: @build_const("target") resolves to the active backend
# name on each target, and an explicit --define target=… still overrides it.
# Single-file (the injection is not manifest-sourced, unlike `version`).
cat > "$proj/src/tgt.l" <<'LYR'
package tgtprobe

@build_const("target")
val TARGET: String = "unknown"

func main(): Int {
  println("target=" + TARGET)
  0
}
LYR
echo "=== dotnet single-file @build_const(\"target\") (no --define) ==="
"$lyric_bin" build "$proj/src/tgt.l" -o "$proj/tgt.dll"
outt="$(dotnet "$proj/tgt.dll")"
echo "dotnet: $outt"
echo "$outt" | grep -qx "target=dotnet" || { echo "::error::well-known target define not auto-injected on dotnet (#5852 M1f)"; exit 1; }
echo "=== jvm single-file @build_const(\"target\") (no --define) ==="
"$lyric_bin" build "$proj/src/tgt.l" --target jvm -o "$proj/tgt.jar"
outtj="$(java -jar "$proj/tgt.jar")"
echo "jvm: $outtj"
echo "$outtj" | grep -qx "target=jvm" || { echo "::error::well-known target define not auto-injected on jvm (#5852 M1f)"; exit 1; }
echo "=== dotnet --define target=custom (override) ==="
"$lyric_bin" build "$proj/src/tgt.l" --define target=custom -o "$proj/tgt2.dll"
outtc="$(dotnet "$proj/tgt2.dll")"
echo "dotnet(--define): $outtc"
echo "$outtc" | grep -qx "target=custom" || { echo "::error::explicit --define target did not override the well-known target (#5852 M1f)"; exit 1; }
# (M1h, #5852) well-known `build_profile` define: `debug` on a normal
# build (pipeParseAndErase fallback), overridable by --define. The
# `release`-on-a-real-`--release --aot`-build case needs clang/ILCompiler, so
# it is asserted in the dedicated `aot-smoke` job (which installs those
# prerequisites), not here in the `build` job.
cat > "$proj/src/prof.l" <<'LYR'
package profprobe

import Std.BuildInfo

func main(): Int {
  println("profile=" + buildInfo().profile)
  0
}
LYR
echo "=== dotnet normal build (expect profile=debug) ==="
"$lyric_bin" build "$proj/src/prof.l" -o "$proj/prof.dll"
outp="$(dotnet "$proj/prof.dll")"
echo "dotnet: $outp"
echo "$outp" | grep -qx "profile=debug" || { echo "::error::normal build did not auto-inject build_profile=debug (#5852 M1h)"; exit 1; }
echo "=== dotnet --define build_profile=release (override) ==="
"$lyric_bin" build "$proj/src/prof.l" --define build_profile=release -o "$proj/prof2.dll"
outpo="$(dotnet "$proj/prof2.dll")"
echo "dotnet(--define): $outpo"
echo "$outpo" | grep -qx "profile=release" || { echo "::error::--define build_profile did not override the debug fallback (#5852 M1h)"; exit 1; }
echo "BuildInfo project version + --define OK (dotnet + jvm: no-define 4.5.6; --define override 9.9.9/7.7.7 + @build_const; well-known target dotnet/jvm + override; build_profile debug/override)" >> "$GITHUB_STEP_SUMMARY"

# docs/63 band B0 (#6279): the profile axis is independent of the shape
# axis. Every other AOT assertion in this workflow pairs `--release
# --aot`, so nothing covered the headline unlock -- `--release` on the
# DEFAULT portable shape -- nor the clean break that a bare `--release`
# no longer produces a native binary. Both are asserted here, on the
# cheap managed path, with no ILC/clang toolchain needed.
echo "=== --release --shape portable (expect profile=release, portable DLL) ==="
"$lyric_bin" build "$proj/src/prof.l" --release --shape portable -o "$proj/prof_rel.dll"
outrel="$(dotnet "$proj/prof_rel.dll")"
echo "dotnet(--release portable): $outrel"
echo "$outrel" | grep -qx "profile=release" \
  || { echo "::error::--release --shape portable did not report build_profile=release (docs/63 B0, #6279)"; exit 1; }

echo "=== bare --release no longer implies AOT (clean break) ==="
rm -f "$proj/src/prof_bare" "$proj/src/prof_bare.dll"
"$lyric_bin" build "$proj/src/prof.l" --release -o "$proj/prof_bare.dll"
# The artifact must be a managed assembly runnable via `dotnet`, NOT a
# native executable: that is precisely what the clean break changed.
outbare="$(dotnet "$proj/prof_bare.dll")"
echo "dotnet(bare --release): $outbare"
echo "$outbare" | grep -qx "profile=release" \
  || { echo "::error::bare --release did not report build_profile=release (docs/63 B0, #6279)"; exit 1; }
file "$proj/prof_bare.dll" | grep -qiE "PE32|MS-DOS|COFF" \
  || { echo "::error::bare --release did not produce a managed PE -- it may still be implying AOT (docs/63 B0 clean break, #6279)"; exit 1; }

echo "=== --debug --aot keeps the debug profile (#6267) ==="
"$lyric_bin" build "$proj/src/prof.l" --debug --shape portable -o "$proj/prof_dbg.dll"
outdbg="$(dotnet "$proj/prof_dbg.dll")"
echo "$outdbg" | grep -qx "profile=debug" \
  || { echo "::error::explicit --debug did not report build_profile=debug (docs/63 B0)"; exit 1; }

echo "profile/shape axes OK (--release portable => release; bare --release => managed PE, not AOT; --debug => debug)" >> "$GITHUB_STEP_SUMMARY"

