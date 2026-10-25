#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-sign-e2e.sh — `lyric plugin keygen`, `sign`, `verify`, `check` and
# `pack --sign-key` (docs/69 §12, D248).
#
#   1. keygen writes an owner-only secret key and a public key, and refuses
#      to overwrite them.
#   2. sign (from --key and from LYRIC_PLUGIN_SIGNING_KEY) writes plugin.sig;
#      check and verify accept the result.
#   3. verify reports K0108 for a changed or added file, K0106 for another
#      key and K0109 for another publisher; check reports the changed file.
#   4. pack --sign-key packs and signs the trusted_notes fixture in one step.
#
# Usage: bash scripts/ci/plugin-sign-e2e.sh <lyric-binary>
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:?usage: plugin-sign-e2e.sh <lyric-binary>}"
case "$LYRIC" in
  /*) ;;
  *) LYRIC="$REPO_ROOT/$LYRIC" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step() { echo; echo "=== $* ==="; }
fail() { echo "::error::$*" >&2; exit 1; }

# expect_failure <code> <description> <command...>: the command must fail and
# its stderr must name <code>.
expect_failure() {
  local code="$1" what="$2"
  shift 2
  if "$@" > "$work/out.txt" 2> "$work/err.txt"; then
    cat "$work/out.txt"
    fail "$what: expected a failure"
  fi
  grep -q -- "$code" "$work/err.txt" || { cat "$work/err.txt"; fail "$what: expected $code"; }
  echo "ok: $what ($code)"
}

step "keygen"
"$LYRIC" plugin keygen -o "$work/acme"
[ -f "$work/acme.key" ] && [ -f "$work/acme.pub" ] || fail "keygen did not write both files"
grep -q '^lyric-ed25519-secret:' "$work/acme.key" || fail "the secret key has the wrong form"
grep -q '^lyric-ed25519:' "$work/acme.pub" || fail "the public key has the wrong form"
perms="$(stat -c '%a' "$work/acme.key" 2>/dev/null || stat -f '%Lp' "$work/acme.key")"
[ "$perms" = "600" ] || fail "the secret key's mode is $perms, not 600"
expect_failure "already exists" "keygen refuses to overwrite" "$LYRIC" plugin keygen -o "$work/acme"
"$LYRIC" plugin keygen -o "$work/other"

step "an artifact"
art="$work/acme.tools-1.2.3"
mkdir -p "$art/lib"
cat > "$art/plugin.json" <<'EOF'
{
  "schema": 1,
  "id": "acme.tools",
  "version": "1.2.3",
  "publisher": "acme",
  "points": [ { "point": "Acme.Api.Tool", "version": "1.0" } ],
  "capabilities": { "required": [], "optional": [] },
  "payloads": [ { "mode": "wasm", "module": "plugin.wasm" } ]
}
EOF
printf 'not really wasm' > "$art/plugin.wasm"
printf 'helper' > "$art/lib/helper.txt"
"$LYRIC" plugin check "$art"

step "sign and verify"
"$LYRIC" plugin sign "$art" --key "$work/acme.key"
[ -f "$art/plugin.sig" ] || fail "sign did not write plugin.sig"
"$LYRIC" plugin check "$art"
"$LYRIC" plugin verify "$art" --key "$work/acme.pub" | tee "$work/verify.txt"
grep -q 'signed by acme' "$work/verify.txt" || fail "verify did not name the publisher"
"$LYRIC" plugin verify "$art" --key "$work/other.pub" --key "$work/acme.pub" --publisher acme
LYRIC_PLUGIN_SIGNING_KEY="$(cat "$work/acme.key")" "$LYRIC" plugin sign "$art"
"$LYRIC" plugin verify "$art" --key "$work/acme.pub"
expect_failure "no signing key" "sign without a key" env -u LYRIC_PLUGIN_SIGNING_KEY "$LYRIC" plugin sign "$art"
printf 'lyric-ed25519-secret:nope\n' > "$work/bad.key"
expect_failure "secret key" "sign with a malformed key" "$LYRIC" plugin sign "$art" --key "$work/bad.key"

step "verification failures"
expect_failure K0106 "another key" "$LYRIC" plugin verify "$art" --key "$work/other.pub"
expect_failure K0109 "another publisher" "$LYRIC" plugin verify "$art" --key "$work/acme.pub" --publisher mallory
printf 'planted' > "$art/lib/extra.dll"
expect_failure K0108 "an added file" "$LYRIC" plugin verify "$art" --key "$work/acme.pub"
expect_failure "not in the signed listing" "check sees the added file" "$LYRIC" plugin check "$art"
rm "$art/lib/extra.dll"
printf 'changed' > "$art/plugin.wasm"
expect_failure K0108 "a changed payload" "$LYRIC" plugin verify "$art" --key "$work/acme.pub"
rm "$art/plugin.sig"
expect_failure K0105 "no plugin.sig" "$LYRIC" plugin verify "$art" --key "$work/acme.pub"

step "pack --sign-key"
"$LYRIC" plugin pack --manifest "$REPO_ROOT/lyric-stdlib/tests/plugin_fixtures/trusted_notes/lyric.toml" \
  --sign-key "$work/acme.key" -o "$work/packed"
packed="$(find "$work/packed" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -1)"
[ -n "$packed" ] && [ -f "$packed/plugin.sig" ] || fail "pack --sign-key did not sign the artifact"
"$LYRIC" plugin check "$packed"
publisher="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["publisher"])' "$packed/plugin.json")"
"$LYRIC" plugin verify "$packed" --key "$work/acme.pub" --publisher "$publisher"

echo
echo "plugin-sign-e2e: all checks passed"
