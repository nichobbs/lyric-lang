#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# db-sqltext-negative-test.sh - lyric-db SqlText negative-compile test
# (#7241, D220).
#
# `DbConnection.query` / `execute` take a `Db.SqlText`, so an injection-shaped
# dynamic String must not type-check. This builds a consumer of lyric-db that
# passes a concatenated String and asserts the build fails; it first builds the
# same consumer with `Db.sql(...)` / `Db.unsafeRawSql(...)` and asserts it
# succeeds, so a build that fails for an unrelated reason cannot pass.
#
# Usage: LYRIC_CLI_PATH=/path/to/lyric bash scripts/ci/db-sqltext-negative-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin"
  exit 1
fi
bin_abs="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"

cat > "$work/lyric.toml" <<TOML
[package]
name = "sqltextneg"
version = "0.1.0"
[project]
name = "SqlTextNeg"
[project.packages]
"SqlTextNeg" = "src"
[dependencies]
"Lyric.Db" = { path = "$REPO_ROOT/lyric-db" }
[nuget]
"Npgsql" = "8.0.3"
"Microsoft.Data.Sqlite" = "8.0.3"
TOML

# $1 is the body of `lookup`.
write_fixture() {
  {
    echo 'package SqlTextNeg'
    echo 'import Std.Core'
    echo 'import Db'
    echo ''
    echo 'func lookup(conn: in DbConnection, name: in String): Result[slice[DbRow], DbError] {'
    echo "  $1"
    echo '}'
    echo ''
    echo 'func main(): Int {'
    echo '  0'
    echo '}'
  } > "$work/src/app.l"
}

# A path dependency must already be built into its own bin/ (no --out).
"$bin_abs" restore --manifest "$REPO_ROOT/lyric-db/lyric.toml" > "$work/db-restore.out" 2>&1 || {
  cat "$work/db-restore.out"
  echo "::error::restore of lyric-db failed"
  exit 1
}
"$bin_abs" build --manifest "$REPO_ROOT/lyric-db/lyric.toml" > "$work/db-build.out" 2>&1 || {
  cat "$work/db-build.out"
  echo "::error::build of lyric-db failed"
  exit 1
}

"$bin_abs" restore --manifest "$work/lyric.toml" > "$work/restore.out" 2>&1 || {
  cat "$work/restore.out"
  echo "::error::restore of the fixture failed"
  exit 1
}

# Positive controls: the audited constructors build.
write_fixture 'conn.query(Db.sql("SELECT id FROM users WHERE name = @p0"), [name])'
"$bin_abs" build --manifest "$work/lyric.toml" > "$work/ok.out" 2>&1 || {
  cat "$work/ok.out"
  echo "::error::positive control (Db.sql) failed to build"
  exit 1
}
write_fixture 'conn.query(Db.unsafeRawSql("SELECT id FROM users"), [])'
"$bin_abs" build --manifest "$work/lyric.toml" > "$work/ok2.out" 2>&1 || {
  cat "$work/ok2.out"
  echo "::error::positive control (Db.unsafeRawSql) failed to build"
  exit 1
}

# Negative: concatenated, interpolated and literal Strings must not compile.
bodies=(
  'conn.query("SELECT id FROM users WHERE name = \x27" + name + "\x27", [])'
  'conn.query("SELECT id FROM users WHERE name = \x27${name}\x27", [])'
  'conn.query("SELECT id FROM users", [])'
)
for body in "${bodies[@]}"; do
  body="$(printf '%b' "$body")"
  write_fixture "$body"
  rc=0
  "$bin_abs" build --manifest "$work/lyric.toml" > "$work/neg.out" 2>&1 || rc=$?
  echo "--- build output (rc=$rc) for: $body ---"
  cat "$work/neg.out"
  if [ "$rc" -eq 0 ]; then
    echo "::error::a raw String reached DbConnection.query and compiled: $body"
    exit 1
  fi
  grep -qE "T[0-9]{4}" "$work/neg.out" || {
    echo "::error::build failed but without a type diagnostic: $body"
    exit 1
  }
done
echo "OK: raw String SQL is rejected by the type system; Db.sql / Db.unsafeRawSql build."
