#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# write-lyric-dotnet-wrapper.sh — overwrite a downloaded AOT `lyric` apphost
# stub with a thin `dotnet lyric.dll` launcher shim (#7025, #6788).
#
# A self-hosted runner of a different CPU architecture than the GitHub-hosted
# runner that built the `build-artifacts`/`stage2-artifacts` upload gets
# "cannot execute binary file: Exec format error" trying to run the native
# apphost stub directly. `dotnet build` (unlike `dotnet publish
# -p:PublishAot=true`) always produces a portable managed `lyric.dll` beside
# the stub, and the stub itself is nothing more than a native launcher that
# immediately hands off to that same managed runtime — so going through
# `dotnet` directly changes nothing observable, on any architecture.
#
# The wrapper resolves its OWN path via `readlink -f "$0"` before taking
# `dirname`, not a bare `dirname "$0"`: a job that also creates a
# `./bin/lyric` dev-parity symlink invokes the wrapper *through* that
# symlink, and bash sets `$0` to the literal invocation path (e.g.
# `./bin/lyric`), not the symlink's resolved target — a bare `dirname "$0"`
# would look for `lyric.dll` next to the symlink instead of next to the real
# wrapper script (#7052).
#
# Was duplicated byte-identically across 14 call sites in ci.yml (#7026,
# #7041) before this extraction (#7042); every call site now just does:
#   lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
#   bash scripts/ci/write-lyric-dotnet-wrapper.sh "$lyric_bin"
# ---------------------------------------------------------------------------
set -euo pipefail

lyric_bin="${1:?usage: write-lyric-dotnet-wrapper.sh <path-to-lyric-apphost>}"

cat > "$lyric_bin" <<'WRAPPER'
#!/usr/bin/env bash
self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
exec dotnet "$(dirname "$self")/lyric.dll" "$@"
WRAPPER
chmod +x "$lyric_bin"
