#!/bin/bash
# SessionStart hook — install the .NET SDK + runtime pinned by
# `compiler/global.json` into `~/.dotnet` so Claude Code on the
# web can `dotnet build Lyric.sln` and run the test projects
# without the agent having to bootstrap dotnet on every cold
# session.
#
# Idempotent: if the right SDK is already on PATH, exits fast.

set -euo pipefail

# Only run in remote (Claude Code on the web) sessions.  Local
# developers manage their own .NET install.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
GLOBAL_JSON="$REPO_ROOT/compiler/global.json"

if [ ! -f "$GLOBAL_JSON" ]; then
    echo "session-start.sh: $GLOBAL_JSON not found; skipping .NET install" >&2
    exit 0
fi

# Pull the pinned SDK version out of global.json.  Falls back to
# the floor of the major.minor.x prefix if the strict version isn't
# available (Microsoft sometimes drops point releases between feed
# refreshes).
SDK_VERSION="$(
    grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$GLOBAL_JSON" \
    | head -1 \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
)"
if [ -z "$SDK_VERSION" ]; then
    echo "session-start.sh: could not parse SDK version from $GLOBAL_JSON" >&2
    exit 1
fi
SDK_MAJOR="${SDK_VERSION%%.*}"
RUNTIME_VERSION="${SDK_MAJOR}.0.0"

DOTNET_DIR="$HOME/.dotnet"
DOTNET_BIN="$DOTNET_DIR/dotnet"

# Make sure subsequent shell commands in this session see ~/.dotnet
# on PATH and use the in-tree install root.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    {
        echo "export PATH=\"$DOTNET_DIR:\$PATH\""
        echo "export DOTNET_ROOT=\"$DOTNET_DIR\""
    } >> "$CLAUDE_ENV_FILE"
fi
export PATH="$DOTNET_DIR:$PATH"
export DOTNET_ROOT="$DOTNET_DIR"

# Idempotent fast path: if the pinned SDK is already installed, no
# work to do.
if [ -x "$DOTNET_BIN" ] \
   && "$DOTNET_BIN" --list-sdks 2>/dev/null | grep -q "^$SDK_VERSION "; then
    echo "session-start.sh: .NET SDK $SDK_VERSION already present at $DOTNET_DIR"
    exit 0
fi

INSTALL_SCRIPT="$(mktemp -t dotnet-install.XXXXXX.sh)"
trap 'rm -f "$INSTALL_SCRIPT"' EXIT

curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$INSTALL_SCRIPT"
chmod +x "$INSTALL_SCRIPT"

# Install the SDK pinned by global.json.  The script also drops the
# matching shared runtime into the same prefix, so a separate
# `--runtime dotnet` invocation isn't needed for the SDK band.
"$INSTALL_SCRIPT" \
    --version "$SDK_VERSION" \
    --install-dir "$DOTNET_DIR"

# Defensive: if the SDK shipped without a matching shared runtime
# (the script's own behaviour varies by RID), pull the runtime
# explicitly so `dotnet exec out.dll` works for emitter tests.
if ! "$DOTNET_BIN" --list-runtimes 2>/dev/null \
        | grep -q "^Microsoft.NETCore.App $SDK_MAJOR\."; then
    "$INSTALL_SCRIPT" \
        --runtime dotnet \
        --version "$RUNTIME_VERSION" \
        --install-dir "$DOTNET_DIR"
fi

echo "session-start.sh: installed .NET SDK $SDK_VERSION + runtime ${SDK_MAJOR}.x at $DOTNET_DIR"
