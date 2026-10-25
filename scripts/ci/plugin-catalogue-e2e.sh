#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-catalogue-e2e.sh — `lyric plugin pack --zip`, `lyric plugin catalogue`
# and `lyric plugin install` (docs/69 §12, D248 Decisions 8-11).
#
#   1. pack --sign-key --zip packs the trusted_notes fixture into a signed
#      artifact and its zip; Python's zipfile reads the zip.
#   2. catalogue init/publisher/add/sign builds a catalogue; verify accepts
#      the zip against it.
#   3. install fetches the catalogue from a directory and over HTTP (a local
#      Python server), checks and extracts the plugin, and the result verifies.
#   4. yank, revoke-key and a tampered zip are refused (K0106/K0110 via the
#      artifact check, K0123), a rollback is refused (K0122), and a rotation
#      signed by both keys is accepted.
#
# Usage: bash scripts/ci/plugin-catalogue-e2e.sh <lyric-binary>
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:?usage: plugin-catalogue-e2e.sh <lyric-binary>}"
case "$LYRIC" in
  /*) ;;
  *) LYRIC="$REPO_ROOT/$LYRIC" ;;
esac
command -v python3 >/dev/null || { echo "::error::python3 is not on PATH" >&2; exit 1; }

work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

step() { echo; echo "=== $* ==="; }
fail() { echo "::error::$*" >&2; exit 1; }
expect_failure() { # code description command...
  local code="$1" what="$2"
  shift 2
  if "$@" > "$work/out.txt" 2> "$work/err.txt"; then
    cat "$work/out.txt"
    fail "$what: expected a failure"
  fi
  grep -q -- "$code" "$work/err.txt" || { cat "$work/err.txt"; fail "$what: expected $code"; }
  echo "ok: $what ($code)"
}

"$LYRIC" plugin keygen -o "$work/catalogue" >/dev/null
"$LYRIC" plugin keygen -o "$work/catalogue2" >/dev/null
"$LYRIC" plugin keygen -o "$work/publisher" >/dev/null
"$LYRIC" plugin keygen -o "$work/rogue" >/dev/null

step "pack --sign-key --zip"
"$LYRIC" plugin pack --manifest "$REPO_ROOT/lyric-stdlib/tests/plugin_fixtures/trusted_notes/lyric.toml" \
  --sign-key "$work/publisher.key" --zip -o "$work/packed"
zip="$work/packed/lyric.test.trusted-notes-1.0.0.zip"
[ -f "$zip" ] || fail "pack --zip wrote no zip"
python3 -I - "$zip" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None
names = z.namelist()
assert all(n.startswith("lyric.test.trusted-notes-1.0.0/") for n in names), names
assert "lyric.test.trusted-notes-1.0.0/plugin.sig" in names
print("zipfile reads", len(names), "entries")
EOF
"$LYRIC" plugin verify "$zip" --key "$work/publisher.pub"

step "catalogue init / publisher / add / sign"
cat="$work/cat"
"$LYRIC" plugin catalogue init "$cat" --name lyric-tests --key "$work/catalogue.key"
"$LYRIC" plugin catalogue publisher "$cat" lyric --key "$work/publisher.pub"
"$LYRIC" plugin catalogue add "$cat" "$zip"
expect_failure "" "catalogue sign with another key" "$LYRIC" plugin catalogue sign "$cat" --key "$work/rogue.key"
"$LYRIC" plugin catalogue sign "$cat" --key "$work/catalogue.key" --expires-in 30
[ -f "$cat/catalogue.sig" ] || fail "sign wrote no catalogue.sig"
"$LYRIC" plugin verify "$zip" --catalogue "$cat" --catalogue-key "$work/catalogue.pub"
cp "$cat/catalogue.json" "$work/catalogue.serial2.json"
cp "$cat/catalogue.sig" "$work/catalogue.serial2.sig"

step "install from a directory"
"$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" \
  --into "$work/plugins"
installed="$work/plugins/lyric.test.trusted-notes-1.0.0"
[ -f "$installed/plugin.json" ] || fail "install wrote no plugin.json"
"$LYRIC" plugin check "$installed"
"$LYRIC" plugin verify "$installed" --key "$work/publisher.pub" --publisher lyric

step "install over HTTP"
port="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
(cd "$cat" && exec python3 -I -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  python3 -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/catalogue.json')" 2>/dev/null && break
  sleep 0.2
done
"$LYRIC" plugin install lyric.test.trusted-notes@1.0.0 --catalogue "http://127.0.0.1:$port" \
  --catalogue-key "$work/catalogue.pub" --into "$work/http-plugins"
[ -f "$work/http-plugins/lyric.test.trusted-notes-1.0.0/plugin.json" ] || fail "the HTTP install wrote nothing"

step "refusals"
expect_failure K0120 "a catalogue key that did not sign" \
  "$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/rogue.pub" --into "$work/x"
cp "$zip" "$work/zip.bak"
printf 'x' >> "$cat/artifacts/lyric.test.trusted-notes-1.0.0.zip"
expect_failure K0123 "a changed zip" \
  "$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/y"
cp "$work/zip.bak" "$cat/artifacts/lyric.test.trusted-notes-1.0.0.zip"
publisher_id="$(python3 -I - "$work/publisher.pub" <<'EOF'
import base64, hashlib, sys
key = base64.b64decode(open(sys.argv[1]).read().strip().split(":", 1)[1])
print(hashlib.sha256(key).digest()[:16].hex())
EOF
)"
"$LYRIC" plugin catalogue revoke-key "$cat" "$publisher_id"
"$LYRIC" plugin catalogue sign "$cat" --key "$work/catalogue.key"
expect_failure K0110 "a revoked publisher key" \
  "$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/z"
expect_failure K0110 "verify sees the revocation" \
  "$LYRIC" plugin verify "$zip" --catalogue "$cat" --catalogue-key "$work/catalogue.pub"
"$LYRIC" plugin catalogue yank "$cat" lyric.test.trusted-notes 1.0.0
"$LYRIC" plugin catalogue sign "$cat" --key "$work/catalogue.key"
expect_failure "no installable entry" "a yanked version" \
  "$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/plugins"

step "rollback and rotation"
cp "$work/catalogue.serial2.json" "$cat/catalogue.json"
cp "$work/catalogue.serial2.sig" "$cat/catalogue.sig"
expect_failure K0122 "an older catalogue" \
  "$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/plugins"
"$LYRIC" plugin catalogue publisher "$cat" lyric --key "$work/publisher.pub"
python3 -I - "$cat/catalogue.json" <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["serial"] = 50
json.dump(c, open(p, "w"), indent=2)
EOF
"$LYRIC" plugin catalogue sign "$cat" --key "$work/catalogue.key" --rotate-to "$work/catalogue2.key"
"$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/plugins"
"$LYRIC" plugin catalogue sign "$cat" --key "$work/catalogue2.key"
"$LYRIC" plugin install lyric.test.trusted-notes --catalogue "$cat" --catalogue-key "$work/catalogue.pub" --into "$work/plugins"
echo "ok: the host followed the rotation to the new catalogue key"

echo
echo "plugin-catalogue-e2e: all checks passed"
