#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# source-generator-restore-e2e.sh — source generators restored from a
# registry or git as signed plugin artifacts, with their signing key pinned in
# lyric.lock (#8580, D266, D248 Decision 7).
#
#   1. `lyric publish` of the Acme.Describe generator (kind =
#      "source-generator") packs and signs its artifact and pushes a package
#      holding only lyric-plugin/ to a local folder feed.
#   2. A consumer depending on it by version builds on dotnet and the JVM; the
#      restore pins the signer's key id in lyric.lock.
#   3. A new version signed by another key is refused until
#      `lyric restore --update Acme.Describe`; `lyric update` keeps the pin.
#   4. `restore --locked` fails on a changed key id; a pinned `key` that did
#      not sign the package fails the restore; a file changed in the restored
#      artifact fails the build (K0108).
#   5. The same artifact restored from a git tag runs too.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"

expected=$'Order { id: Int, note: String }\nPoint { x: Long, y: Long }'

fail() {
  echo "::error::$1"
  exit 1
}

check_output() {
  local label="$1" actual="$2"
  if [ "$actual" != "$expected" ]; then
    echo "expected:"; echo "$expected"
    echo "actual:"; echo "$actual"
    fail "$label printed unexpected output"
  fi
  echo "$label: ok"
}

# Runs a command that must fail, and requires its output to contain a text.
expect_failure() {
  local label="$1" needle="$2"
  shift 2
  local rc=0
  "$@" > "$work/expect.out" 2>&1 || rc=$?
  cat "$work/expect.out"
  [ "$rc" -ne 0 ] || fail "$label: expected a failure, got exit 0"
  grep -qF -- "$needle" "$work/expect.out" || fail "$label: expected the output to mention: $needle"
  echo "$label: refused as expected"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Private copies of the generator, the app and the SDK, keeping their
# relative paths (see source-generator-e2e.sh).
mkdir -p "$work/src/examples/generators"
cp -r examples/generators/app examples/generators/describe "$work/src/examples/generators/"
cp -r lyric-generator-sdk "$work/src/"
rm -rf "$work"/src/examples/generators/*/bin "$work/src/lyric-generator-sdk/bin"
gen="$work/src/examples/generators/describe"
"$lyric_bin" build --manifest "$work/src/lyric-generator-sdk/lyric.toml"

key1="$REPO_ROOT/examples/plugins/keys/example-publisher.key"
pub1="$(cat "$REPO_ROOT/examples/plugins/keys/example-publisher.pub")"
"$lyric_bin" plugin keygen -o "$work/rotated"
key2="$work/rotated.key"
pub2="$(cat "$work/rotated.pub")"

feed="$work/feed"
mkdir -p "$feed"
export NUGET_PACKAGES="$work/nuget-packages"

# ── 1. publish ──────────────────────────────────────────────────────────────
"$lyric_bin" publish --manifest "$gen/lyric.toml" --sign-key "$key1" \
  --registry "$feed" --api-key local -o "$work/nupkg"
nupkg="$(find "$feed" -iname 'acme.describe.0.1.0.nupkg' | head -1)"
[ -n "$nupkg" ] || { ls -R "$feed"; fail "publish did not push Acme.Describe 0.1.0 to $feed"; }
listing="$(unzip -Z1 "$nupkg")"
grep -qx 'lyric-plugin/signer.pub' <<< "$listing" || fail "the package has no lyric-plugin/signer.pub"
grep -qx 'lyric-plugin/acme.describe-0.1.0/plugin.sig' <<< "$listing" || fail "the package has no signed artifact"
if grep -q '^lib/' <<< "$listing"; then
  fail "a generator package must not carry a lib/ assembly"
fi
echo "publish: ok"

# ── 2. consume by version ───────────────────────────────────────────────────
app="$work/consumer"
cp -r "$work/src/examples/generators/app" "$app"
cat > "$app/nuget.config" <<XML
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$feed" />
  </packageSources>
</configuration>
XML
set_dep() {
  sed -i "s|^\"Acme.Describe\" = .*|\"Acme.Describe\" = $1|" "$app/lyric.toml"
}
set_dep '"0.1.0"'

build_and_check() {
  local label="$1"
  "$lyric_bin" build --manifest "$app/lyric.toml" --target dotnet -o "$work/out/dotnet/Acme.App.dll"
  check_output "$label (dotnet)" "$(dotnet "$work/out/dotnet/Acme.App.dll")"
}
build_and_check "registry generator"
"$lyric_bin" build --manifest "$app/lyric.toml" --target jvm -o "$work/out/jvm/Acme.App.jar"
check_output "registry generator (jvm)" "$(java -jar "$work/out/jvm/Acme.App.jar" 2>/dev/null)"
id1="$(grep -A6 'name = "Acme.Describe"' "$app/lyric.lock" | sed -n 's/^key = "\(.*\)"$/\1/p')"
[ -n "$id1" ] || { cat "$app/lyric.lock"; fail "lyric.lock pins no key for Acme.Describe"; }
echo "pinned key: $id1"

# ── 3. a new key needs --update ─────────────────────────────────────────────
"$lyric_bin" publish --manifest "$gen/lyric.toml" --sign-key "$key2" --package-version 0.1.1 \
  --registry "$feed" --api-key local -o "$work/nupkg"
set_dep '"0.1.1"'
expect_failure "a new signing key" "lyric restore --update Acme.Describe" \
  "$lyric_bin" restore --manifest "$app/lyric.toml"
expect_failure "lyric update with a new signing key" "lyric restore --update Acme.Describe" \
  "$lyric_bin" update --manifest "$app/lyric.toml"
grep -q "key = \"$id1\"" "$app/lyric.lock" || fail "a failed lyric update must keep the previous lyric.lock"
"$lyric_bin" restore --manifest "$app/lyric.toml" --update Acme.Describe
id2="$(grep -A6 'name = "Acme.Describe"' "$app/lyric.lock" | sed -n 's/^key = "\(.*\)"$/\1/p')"
[ -n "$id2" ] && [ "$id2" != "$id1" ] || fail "--update did not pin the new key (was $id1, now $id2)"
build_and_check "after --update"
"$lyric_bin" update --manifest "$app/lyric.toml"
grep -q "key = \"$id2\"" "$app/lyric.lock" || fail "lyric update dropped the pinned key"

# ── 4. --locked, a pinned key, a changed file ───────────────────────────────
"$lyric_bin" restore --manifest "$app/lyric.toml" --locked
cp "$app/lyric.lock" "$work/lock.saved"
sed -i "s/key = \"$id2\"/key = \"$id1\"/" "$app/lyric.lock"
expect_failure "--locked with a changed key" "signing key changed" \
  "$lyric_bin" restore --manifest "$app/lyric.toml" --locked
cp "$work/lock.saved" "$app/lyric.lock"

set_dep "{ version = \"0.1.1\", key = \"$pub1\" }"
expect_failure "a pinned key that did not sign the package" "K0106" \
  "$lyric_bin" restore --manifest "$app/lyric.toml"
set_dep "{ version = \"0.1.1\", key = \"$pub2\" }"
"$lyric_bin" restore --manifest "$app/lyric.toml"
build_and_check "pinned key"

restored_dll="$NUGET_PACKAGES/acme.describe/0.1.1/lyric-plugin/acme.describe-0.1.0/dotnet/Acme.Describe.dll"
[ -f "$restored_dll" ] || fail "no restored artifact at $restored_dll"
printf 'x' >> "$restored_dll"
expect_failure "a changed file in the restored artifact" "K0108" \
  "$lyric_bin" build --manifest "$app/lyric.toml" --target dotnet -o "$work/out/dotnet/Acme.App.dll"

# ── 5. from git ─────────────────────────────────────────────────────────────
gitc="git -c commit.gpgsign=false -c tag.gpgsign=false -c user.email=t@t -c user.name=t"
repo="$work/gitgen"
mkdir -p "$repo"
cp "$gen/lyric.toml" "$repo/"
cp -r "$gen/bin/generator-publish/lyric-plugin" "$repo/"
( cd "$repo" && git init -q -b main . && $gitc add -A && $gitc commit -q -m generator && $gitc tag v0.1.1 )
rm -f "$app/lyric.lock"
set_dep "{ git = \"file://$repo\", tag = \"v0.1.1\" }"
build_and_check "git generator"
grep -A6 'name = "Acme.Describe"' "$app/lyric.lock" | grep -q "key = \"$id2\"" ||
  { cat "$app/lyric.lock"; fail "the git generator's key is not pinned"; }

echo "source generator restore e2e: ok"
