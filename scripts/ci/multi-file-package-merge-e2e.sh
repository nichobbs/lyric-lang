#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# multi-file-package-merge-e2e.sh: a package of several files builds from its
# files' own parses (#8234, docs/19).  Through the real CLI, on each target:
#   - a package whose files carry leading comments, `//!` docs, file-level
#     annotations (one per file, one shared, two on a line), a block comment
#     in the header, an import with a trailing comment, and a file of
#     comments only, builds and runs;
#   - declarations a header block comment hides stay hidden, even when the
#     comment's delimiters share lines with annotations (`trick_hid2`);
#   - a file that declares another package is B0013, against its own path
#     and line;
#   - a file whose header does not parse (`otherpkg`) is reported against its
#     own path, with B0013 for the other package its tokens name;
#   - a file with no `package` declaration is P0020, against its own path;
#   - files that disagree on the verification level are B0014.
#
#   bash scripts/ci/multi-file-package-merge-e2e.sh [dotnet] [jvm] [native]
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(dotnet jvm)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# project <name>: a fresh project whose one package, `Mf`, is `src/`.
project() {
  local dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir/src"
  cat > "$dir/lyric.toml" <<'TOML'
[package]
name = "Mf"
version = "0.1.0"

[project]
name = "Mf"
output = "single"
output_assembly = "Mf.dll"

[project.packages]
"Mf" = "src"
TOML
  echo "$dir"
}

out_path() {
  case "$1" in
    dotnet) echo "out/Mf.dll" ;;
    jvm) echo "out/Mf.jar" ;;
    native) echo "out/mf" ;;
  esac
}

# runs <label> <dir> <target> <expected stdout>
runs() {
  local label="$1" dir="$2" target="$3" want="$4" got rc=0
  (cd "$dir" && "$lyric_bin" build --manifest lyric.toml --target "$target" -o "$(out_path "$target")") > "$work/log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$target] $label: the build failed"; cat "$work/log"; fail=1; return
  fi
  rc=0
  got="$(cd "$dir" && "$lyric_bin" run --manifest lyric.toml --target "$target" 2>"$work/err")" || rc=$?
  got="$(printf '%s\n' "$got" | grep -v '^built ' || true)"
  if [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
    echo "FAIL [$target] $label: expected '$want', got '$got' (exit $rc)"; cat "$work/err"; fail=1; return
  fi
  echo "PASS [$target] $label"
}

# rejected <label> <dir> <target> <regex the output must match>...
rejected() {
  local label="$1" dir="$2" target="$3" rc=0
  shift 3
  (cd "$dir" && "$lyric_bin" build --manifest lyric.toml --target "$target" -o "$(out_path "$target")") > "$work/log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL [$target] $label: the build succeeded"; cat "$work/log"; fail=1; return
  fi
  local pat
  for pat in "$@"; do
    if ! grep -Eq -- "$pat" "$work/log"; then
      echo "FAIL [$target] $label: no line matches '$pat'"; cat "$work/log"; fail=1; return
    fi
  done
  echo "PASS [$target] $label"
}

for target in "${targets[@]}"; do
  # A well-formed package of several files, with every kind of header.
  d="$(project shapes)"
  cat > "$d/src/a_main.l" <<'EOF'
// Copyright line before the docs.
//! The package's entry file.
@runtime_checked
package Mf

import Std.Core // the prelude, spelled out
import Std.String as Str

func main(): Unit {
  println(Str.toUpper(greeting()) + " " + toString(answer()) + " " + toString(counted()))
}
EOF
  cat > "$d/src/b_values.l" <<'EOF'
/* A block comment before the package line:
package Wrong
import Not.A.Package
@proof_required
*/
@runtime_checked @io
package Mf

/* and one between the header and the items */
pub func greeting(): String {
  "hello"
}

pub func answer(): Int {
  42
}
EOF
  cat > "$d/src/c_more.l" <<'EOF'
//! Another file, with no annotation of its own.
package Mf

import Std.String as Str
import Std.Collections

pub func counted(): Int {
  val xs: List[String] = newList()
  xs.add(Str.toLower("A"))
  xs.count
}
EOF
  cat > "$d/src/d_notes.l" <<'EOF'
// A file of comments only adds nothing to the package.
/* not even
   this */
EOF
  runs "every header shape merges" "$d" "$target" "HELLO 42 1"

  # trick_hid2's comment: the declarations between the two annotation lines
  # are commented out, so `pick` is b's alone.
  d="$(project hidden)"
  cat > "$d/src/a_main.l" <<'EOF'
@runtime_checked
package Mf

func main(): Unit {
  println(toString(pick()))
}
EOF
  cat > "$d/src/b_pick.l" <<'EOF'
@runtime_checked /*
pub func pick(): Int {
  2
}
@runtime_checked */
package Mf

pub func pick(): Int {
  1
}
EOF
  runs "a header block comment hides what it holds" "$d" "$target" "1"

  # trick_hid2 as reported: the files also disagree on the verification level.
  d="$(project trick)"
  cp "$d/../hidden/src/a_main.l" "$d/src/a_main.l"
  sed -i 's/^@runtime_checked$/@proof_required/' "$d/src/a_main.l"
  cp "$d/../hidden/src/b_pick.l" "$d/src/b_pick.l"
  rejected "files disagreeing on the verification level" "$d" "$target" \
    "src/b_pick\.l: error\[B0014\] 1:1: this file is @runtime_checked, but .*a_main\.l:1 is @proof_required"

  # A file that declares another package.
  d="$(project otherpkg)"
  printf 'package Mf\n\nfunc main(): Unit {\n  println("x")\n}\n' > "$d/src/a_main.l"
  printf '//! Lost.\n\npackage Elsewhere\n\npub func f(): Int {\n  1\n}\n' > "$d/src/b_other.l"
  rejected "a file of another package" "$d" "$target" \
    "src/b_other\.l: error\[B0013\] 3:9: this file declares package Elsewhere, but it is a file of package Mf"

  # otherpkg as reported: a broken annotation before another package line.
  d="$(project broken)"
  printf '@proof_required\npackage Mf\n\nfunc main(): Unit {\n  println("x")\n}\n' > "$d/src/a_main.l"
  printf '@runtime_checked(((\npackage Elsewhere\n\npub func f(): Int {\n  1\n}\n' > "$d/src/b_other.l"
  rejected "a file whose header does not parse" "$d" "$target" "src/b_other\.l: error\[P[0-9]{4}\] " \
    "src/b_other\.l: error\[B0013\] 2:9: this file declares package Elsewhere"

  # A file with no package declaration.
  d="$(project headerless)"
  printf 'package Mf\n\nfunc main(): Unit {\n  println("x")\n}\n' > "$d/src/a_main.l"
  printf '// helpers\npub func f(): Int {\n  1\n}\n' > "$d/src/b_bare.l"
  rejected "a file with no package declaration" "$d" "$target" "src/b_bare\.l: error\[P0020\] 2:1: "
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
