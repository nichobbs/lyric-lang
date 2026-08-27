#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-auto-ffi-fixture.sh — compile the JVM auto-FFI instance/constructor
# overload-scoring fixture (#6662) into a jar and print its path on stdout.
#
# lyric-compiler/lyric/auto_ffi_jvm_self_test.l resolves
# `lyric.autoffi.fixture.AutoFfiOverloadFixture` through auto-FFI at COMPILE
# time, so the jar must exist and be on LYRIC_FFI_JARS before that file is
# compiled. Usage:
#
#   jar_path="$(bash scripts/ci/build-auto-ffi-fixture.sh)"
#   export LYRIC_FFI_JARS="$jar_path"
#   bash scripts/ci/self-test.sh --target jvm lyric-compiler/lyric/auto_ffi_jvm_self_test.l
#
# Requires `javac` and `jar` on PATH (same JDK requirement as every other
# --target jvm self-test step).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/lyric-compiler/jvm/testdata/AutoFfiOverloadFixture.java"
OUT_DIR="$REPO_ROOT/.bootstrap/auto-ffi-fixture"
CLASSES_DIR="$OUT_DIR/classes"
JAR_PATH="$OUT_DIR/auto-ffi-overload-fixture.jar"

if [ ! -f "$SRC" ]; then
  echo "::error::build-auto-ffi-fixture.sh: missing $SRC" >&2
  exit 1
fi

mkdir -p "$CLASSES_DIR"
javac -d "$CLASSES_DIR" "$SRC"
jar cf "$JAR_PATH" -C "$CLASSES_DIR" .

echo "$JAR_PATH"
