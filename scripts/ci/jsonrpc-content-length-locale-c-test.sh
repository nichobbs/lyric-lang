#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jsonrpc-content-length-locale-c-test.sh — a real
# `JsonRpc.Stdio.newContentLengthTransport()` echo program (built as a
# throwaway consumer of lyric-jsonrpc) reads one Content-Length-framed
# message from stdin and writes the exact same payload back with the same
# framing, run under `LC_ALL=C LANG=C` (#7513) with a non-ASCII JSON
# payload, byte-diffed against the expected wire bytes with `cmp`.
#
# `ContentLengthTransport`'s send/receive already go through byte-level
# primitives (`Std.Console.writeStdoutBytes` / the raw `StdinReader`, see
# stdio.l's module doc), so this suite is a confirmatory regression test:
# it pins that the JSON-RPC LSP-style framing used by `lyric-mcp`'s
# streamable-HTTP-adjacent stdio transports stays byte-correct under a
# C/POSIX locale even as `System.out`/`System.err`/`System.in` are rebound
# by `Jvm.Codegen.emitConsoleUtf8Setup`.
#
# Usage: jsonrpc-content-length-locale-c-test.sh <lyric-binary> [--target jvm]
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: jsonrpc-content-length-locale-c-test.sh <lyric-binary> [--target jvm]}"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/echoapp/src"
cat > "$work/echoapp/lyric.toml" <<TOML
[package]
name = "clLocaleEchoApp"
version = "0.1.0"

[project]
name = "ClLocaleEchoApp"
output_assembly = "ClLocaleEchoApp.dll"

[project.packages]
"ClLocaleEchoApp" = "src"

[dependencies]
"Lyric.JsonRpc" = { path = "$REPO_ROOT/lyric-jsonrpc" }
TOML
cat > "$work/echoapp/src/main.l" <<'LYR'
package ClLocaleEchoApp

import Std.Core
import JsonRpc
import JsonRpc.Stdio

func main(): Int {
  val transport: RpcTransport = newContentLengthTransport()
  match transport.receive() {
    case Ok(Some(body)) -> {
      transport.send(body)
      0
    }
    case Ok(None) -> {
      transport.send("{\"error\":\"eof\"}")
      1
    }
    case Err(e) -> {
      transport.send("{\"error\":\"" + e + "\"}")
      1
    }
  }
}
LYR

payload='{"jsonrpc":"2.0","id":1,"result":{"text":"café 😀 中文"}}'
python3 -c '
import sys
payload = sys.argv[1]
body = payload.encode("utf-8")
sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii"))
sys.stdout.buffer.write(body)
' "$payload" > "$work/expected"

echo "=== build lyric-jsonrpc (path dependency) ==="
"$LYRIC_BIN" build --manifest lyric-jsonrpc/lyric.toml > /dev/null

echo "=== build echoapp ($* dependency resolution check) ==="
"$LYRIC_BIN" build --manifest "$work/echoapp/lyric.toml" > /dev/null

LC_ALL=C LANG=C "$LYRIC_BIN" run --manifest "$work/echoapp/lyric.toml" "$@" \
  < "$work/expected" > "$work/actual_raw"
# `lyric run` prints its own "built <path> in <N>ms" progress line to
# stdout ahead of the program's own output; strip it before comparing raw
# bytes, same as console-stdout-bytes-test.sh.
sed '/^built /d' "$work/actual_raw" > "$work/actual"

if ! cmp -s "$work/actual" "$work/expected"; then
  echo "jsonrpc-content-length-locale-c-test: FAILED — echoed Content-Length frame did not match under LC_ALL=C" >&2
  echo "expected:" >&2
  od -An -tx1z "$work/expected" >&2
  echo "actual:" >&2
  od -An -tx1z "$work/actual" >&2
  exit 1
fi
echo "jsonrpc-content-length-locale-c-test: ok ($LYRIC_BIN run $* ... under LC_ALL=C)"
