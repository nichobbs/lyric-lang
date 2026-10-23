#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-sdk-e2e.sh — end-to-end test of `lyric plugin sdk`, `lyric plugin
# pack` and `lyric plugin check` (D207 Decisions 3-6, docs/69 §13).
#
#   1. Generates the C#, Java and TypeScript SDKs for the sample API package
#      scripts/ci/plugin-sdk/api/, builds a small plugin in each language
#      against its SDK (dotnet build, javac, tsc), and drives each with
#      scripts/ci/plugin-sdk/host.py, a scripted host speaking the D207
#      protocol: manifest probe, handshake, point calls over every boundary
#      type, reverse capability calls and the boundary error codes.
#   2. Packs scripts/ci/plugin-sdk/pack-fixture/ (a hand-written plugin entry
#      point) for dotnet, jvm and native, checks the artifact with
#      `lyric plugin check`, runs every payload from the artifact, and checks
#      that broken artifacts are reported.
#   3. With --with-wasm, also packs a wasm32-wasi payload: the pinned wasi-sdk
#      and wasmtime are downloaded and sha256-checked (the versions
#      scripts/ci/wasm32-wasi-rt-tests.sh uses) unless WASI_SDK_PATH and
#      LYRIC_WASMTIME already name them.
#
# Needs ./bin/lyric (`make lyric`), python3, dotnet, a JDK 21+, node 18+ with
# tsc (installed into a temporary directory with npm when not on PATH), and
# clang for the native payload.
#
# Usage: bash scripts/ci/plugin-sdk-e2e.sh [--with-wasm]
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

with_wasm=0
for arg in "$@"; do
  case "$arg" in
    --with-wasm) with_wasm=1 ;;
    *) echo "usage: bash scripts/ci/plugin-sdk-e2e.sh [--with-wasm]" >&2; exit 2 ;;
  esac
done

LYRIC="${LYRIC:-$REPO_ROOT/bin/lyric}"
if [ ! -x "$LYRIC" ]; then
  echo "::error::$LYRIC not found; run 'make lyric' first" >&2
  exit 1
fi
for tool in python3 dotnet javac java node; do
  command -v "$tool" >/dev/null || { echo "::error::$tool is not on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixtures="$REPO_ROOT/scripts/ci/plugin-sdk"
host="$fixtures/host.py"

step() { echo; echo "=== $* ==="; }

expect_failure() { # description, command...
  local what="$1"; shift
  if "$@" >"$work/neg.out" 2>&1; then
    echo "::error::$what: expected a failure, got exit 0" >&2
    cat "$work/neg.out" >&2
    exit 1
  fi
  echo "ok (fails as expected): $what"
}

expect_output() { # description, fragment
  if ! grep -qF -- "$2" "$work/neg.out"; then
    echo "::error::$1: output does not mention '$2'" >&2
    cat "$work/neg.out" >&2
    exit 1
  fi
}

step "embedded SDK runtimes are current"
python3 scripts/gen_plugin_sdk_runtime.py --check

step "lyric plugin sdk"
for lang in csharp java typescript; do
  "$LYRIC" plugin sdk --api "$fixtures/api" --lang "$lang" -o "$work/sdk-$lang"
done
expect_failure "an unknown language" "$LYRIC" plugin sdk --api "$fixtures/api" --lang cobol -o "$work/sdk-x"
expect_output "an unknown language" "unknown language 'cobol'"
mkdir -p "$work/bad-api"
printf 'package Bad.Api\n\nimport Std.Core\n\n@plugin_point(version = "1.0")\npub interface P {\n  func f(): Int\n}\n' >"$work/bad-api/api.l"
expect_failure "a point method that does not return Result" "$LYRIC" plugin sdk --api "$work/bad-api" --lang java -o "$work/sdk-x"
expect_output "a point method that does not return Result" "must return Result[T, E]"
[ ! -e "$work/sdk-x" ] || { echo "::error::a failed sdk run wrote files" >&2; exit 1; }

step "C# plugin"
mkdir -p "$work/cs"
cp "$fixtures/csharp/"* "$work/cs/"
dotnet build "$work/cs/DemoPlugin.csproj" -nologo -v q -p:SdkDir="$work/sdk-csharp" -o "$work/cs/out"
python3 "$host" demo.greeter-csharp dotnet "$work/cs/out/DemoPlugin.dll"

step "Java plugin"
mkdir -p "$work/java-classes"
# shellcheck disable=SC2046
javac -Xlint:all -Werror -d "$work/java-classes" $(find "$work/sdk-java" -name '*.java') "$fixtures/java/DemoPlugin.java"
python3 "$host" demo.greeter-java java -cp "$work/java-classes" DemoPlugin

step "TypeScript plugin"
ts="$work/ts"
mkdir -p "$ts/sdk"
cp "$fixtures/typescript/"* "$ts/"
cp "$work/sdk-typescript/"*.ts "$ts/sdk/"
# @types/node (and tsc, when it is not on PATH) come from npm at pinned versions.
npm_pkgs=("@types/node@22.10.2")
command -v tsc >/dev/null || npm_pkgs+=("typescript@5.7.2")
(cd "$ts" && npm install --no-audit --no-fund --no-save "${npm_pkgs[@]}" >/dev/null)
tsc_bin="$(command -v tsc || echo "$ts/node_modules/.bin/tsc")"
(cd "$ts" && "$tsc_bin" -p .)
python3 "$host" demo.greeter-typescript node "$ts/dist/plugin.js"

step "lyric plugin pack (dotnet, jvm, native)"
[ -f lyric-rt/build/lyric_rt.a ] || make -C lyric-rt >/dev/null
targets="dotnet,jvm,native"
wasmtime_bin=""
if [ "$with_wasm" = 1 ]; then
  if [ -z "${WASI_SDK_PATH:-}" ] || [ -z "${LYRIC_WASMTIME:-}" ]; then
    WASI_SDK_VERSION="34"
    WASI_SDK_SHA256="b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4"
    WASMTIME_VERSION="49.0.3"
    WASMTIME_SHA256="4001225413f208345b980525f31c4080e1873808b38d0ddc7918497340667fbb"
    tools="${LYRIC_WASM_TOOLCACHE:-${RUNNER_TEMP:-$work}/wasm-tools}"
    mkdir -p "$tools"
    fetch() { # url sha256 dest
      if [ ! -f "$3" ]; then
        curl -fsSL "$1" -o "$3.part"
        echo "$2  $3.part" | sha256sum -c -
        mv "$3.part" "$3"
      fi
    }
    if [ ! -d "$tools/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux" ]; then
      fetch "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux.tar.gz" \
        "$WASI_SDK_SHA256" "$tools/wasi-sdk.tar.gz"
      tar -xzf "$tools/wasi-sdk.tar.gz" -C "$tools"
    fi
    if [ ! -d "$tools/wasmtime-v${WASMTIME_VERSION}-x86_64-linux" ]; then
      fetch "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-x86_64-linux.tar.xz" \
        "$WASMTIME_SHA256" "$tools/wasmtime.tar.xz"
      tar -xJf "$tools/wasmtime.tar.xz" -C "$tools"
    fi
    export WASI_SDK_PATH="$tools/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux"
    export LYRIC_WASMTIME="$tools/wasmtime-v${WASMTIME_VERSION}-x86_64-linux/wasmtime"
  fi
  [ -f lyric-rt/build-wasm32-wasi/lyric_rt.a ] || make -C lyric-rt wasm32-wasi WASI_SDK="$WASI_SDK_PATH" >/dev/null
  targets="$targets,wasm"
  wasmtime_bin="$LYRIC_WASMTIME"
fi
"$LYRIC" plugin pack --manifest "$fixtures/pack-fixture/lyric.toml" --targets "$targets" -o "$work/packed"
artifact="$work/packed/demo.pack-fixture-0.3.0"
"$LYRIC" plugin check "$artifact"
python3 "$fixtures/check_artifact.py" "$artifact" "$targets" ${wasmtime_bin:+"$wasmtime_bin"}
[ ! -e "$work/packed/.lyric-pack-staging" ] || { echo "::error::pack left its staging directory behind" >&2; exit 1; }

step "lyric plugin check reports broken artifacts"
broken="$work/broken/demo.pack-fixture-0.3.0"
mkdir -p "$(dirname "$broken")"
cp -r "$artifact" "$broken"
rm -f "$broken"/jvm/*.jar
python3 - "$broken/plugin.json" <<'EOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["points"][0]["version"] = "1.2.0"
doc["payloads"].append({"mode": "process", "os": "plan9", "arch": "x86_64", "command": ["native/x"]})
json.dump(doc, open(path, "w"))
EOF
expect_failure "a broken artifact" "$LYRIC" plugin check "$broken"
expect_output "a missing payload file" "payloads[1].command[2]: file"
expect_output "a malformed point version" "points[0].version"
expect_output "an unknown os" "unknown os \"plan9\""
expect_failure "a directory without plugin.json" "$LYRIC" plugin check "$work/sdk-java"
expect_output "a directory without plugin.json" "no plugin.json"
expect_failure "pack with an unknown target" "$LYRIC" plugin pack --manifest "$fixtures/pack-fixture/lyric.toml" --targets dotnet,beam -o "$work/packed2"
expect_output "pack with an unknown target" "unknown target 'beam'"

echo
echo "plugin SDK and pack end-to-end tests passed"
