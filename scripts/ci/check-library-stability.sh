#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-library-stability.sh — every ecosystem library declares
# `[package] stability` in its lyric.toml, and its README's
# "**Stability:** `<level>`" line says the same thing (D552 item 4).
#
#   bash scripts/ci/check-library-stability.sh
#
# Levels: stable | experimental | incomplete.  The graphics, window, GPU,
# text, draw, game, access and unicode libraries are out of scope (D548).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

out_of_scope=" lyric-access lyric-draw lyric-game lyric-gpu lyric-gpu-window lyric-stdlib lyric-text lyric-unicode lyric-unicode-dict lyric-window "
bad=0
checked=0

for toml in lyric-*/lyric.toml; do
  lib="${toml%%/*}"
  case "$out_of_scope" in *" $lib "*) continue ;; esac

  manifest=$(sed -n '/^\[package\]/,/^\[/{s/^stability[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p}' "$toml" | head -1)
  case "$manifest" in
    stable|experimental|incomplete) ;;
    "") echo "::error file=$toml::$lib: [package] stability is not declared"; bad=1; continue ;;
    *)  echo "::error file=$toml::$lib: [package] stability = \"$manifest\" is not stable, experimental or incomplete"; bad=1; continue ;;
  esac

  readme="$lib/README.md"
  if [ ! -f "$readme" ]; then
    echo "::error file=$toml::$lib: no README.md to carry the Stability line"; bad=1; continue
  fi
  readme_level=$(sed -n 's/^\*\*Stability:\*\* `\([a-z]*\)`.*/\1/p' "$readme" | head -1)
  if [ -z "$readme_level" ]; then
    echo "::error file=$readme::$lib: README has no line of the form: **Stability:** \`$manifest\`"; bad=1; continue
  fi
  if [ "$readme_level" != "$manifest" ]; then
    echo "::error file=$readme::$lib: README says $readme_level but lyric.toml says $manifest"; bad=1; continue
  fi
  checked=$((checked + 1))
done

if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "check-library-stability: $checked libraries agree"
