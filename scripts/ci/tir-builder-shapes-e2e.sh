#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tir-builder-shapes-e2e.sh - source shapes the TIR builder must build (docs/70
# phase 3a, D483).  Each program is built with `lyric build --verify-ir`; every
# function body must build and the verifier must report nothing.  Programs that
# return an exit code are also run, so the shape means what it says.
#
# Usage: tir-builder-shapes-e2e.sh [path/to/lyric]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
LYRIC="$(cd "$(dirname "$LYRIC")" && pwd)/$(basename "$LYRIC")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export NuGetAudit=false
fail=0

# check NAME EXIT_CODE <<< source
check() {
  local name="$1" want="$2" src="$WORK/$1.l" log="$WORK/$1.log"
  cat > "$src"
  (cd "$WORK" && "$LYRIC" build --verify-ir "$src" -o "$WORK/$name.dll" >"$log" 2>&1)
  local line
  line="$(grep "^TIR build census" "$log" | head -1)"
  local built total
  built="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$line")"
  total="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$line")"
  if [[ -z "$line" || "$built" != "$total" ]]; then
    echo "FAIL ($name): $built of $total bodies built"; grep -E "first error" "$log" | head -3; fail=1; return
  fi
  if ! grep -q "^I0003 census .*: 0 diagnostic" "$log"; then
    echo "FAIL ($name): the verifier rejected a built body"; grep "I0003" "$log" | head -3; fail=1; return
  fi
  if [[ -n "$want" ]]; then
    (cd "$WORK" && dotnet "$name.dll" >/dev/null 2>&1)
    local got=$?
    if [[ "$got" != "$want" ]]; then echo "FAIL ($name): exit code $got, want $want"; fail=1; return; fi
  fi
  echo "ok   $name"
}

check collection_arguments 7 <<'LYRIC'
package Shapes1
import Std.Core
import Std.Collections

record Holder {
  items: List[Int]
  names: List[String] = newList()
}

func count(xs: in List[Int]): Int { xs.count }

func keysOf[K, V](m: in Map[K, V]): List[K] {
  val result: List[K] = newListWithCapacity(m.count)
  result
}

func main(): Int {
  val h = Holder(items = newList())
  h.items.add(7)
  val none: Map[String, Int] = newMap()
  count(newList()) + keysOf(none).count + h.items[0]
}
LYRIC

check branches_that_leave 3 <<'LYRIC'
package Shapes2
import Std.Core

func pick(o: in Option[Int]): Option[Int] {
  match o {
    case Some(e) -> return Some(value = e + 1)
    case None -> return o
  }
  return o
}

func main(): Int {
  match pick(Some(value = 2)) {
    case Some(v) -> v
    case None -> 0
  }
}
LYRIC

check interface_upcasts 5 <<'LYRIC'
package Shapes3
import Std.Core

interface Link {
  func id(self: in Link): Int
}

record Direct { n: Int }

impl Link for Direct {
  func id(self: in Direct): Int { self.n }
}

record Conn {
  link: Option[Link]
}

func make(flag: in Bool): Link {
  if flag { Direct(n = 5) } else { Direct(n = 6) }
}

func main(): Int {
  val c = Conn(link = Some(value = Direct(n = 5)))
  val none = Conn(link = None)
  match c.link {
    case Some(l) -> if make(true).id() == l.id() { l.id() } else { 0 }
    case None -> 0
  }
}
LYRIC

mkdir -p "$WORK/proj/src/a" "$WORK/proj/src/b"
cat > "$WORK/proj/lyric.toml" <<'TOML'
[package]
name = "Shapes"
version = "0.1.0"

[project]
name = "Shapes"
output = "single"
output_assembly = "Shapes.dll"

[project.packages]
"A" = "src/a"
"B" = "src/b"
TOML
cat > "$WORK/proj/src/a/a.l" <<'LYRIC'
package A
import Std.Core

pub record Err2 { code: Int }

pub func Err2.message(e: in Err2): String { "code" }

type Id = String

pub func Id.shout(s: in Id): Int { 4 }
LYRIC
cat > "$WORK/proj/src/b/b.l" <<'LYRIC'
package B
import A as Pk
import Std.Core

pub func main(): Int {
  val e = Pk.Err2(code = 1)
  Pk.Err2.message(e).length
}
LYRIC
(cd "$WORK/proj" && "$LYRIC" build --verify-ir --manifest lyric.toml --target dotnet >"$WORK/proj.log" 2>&1)
if grep -q "TIR build census \[.*src/b/b.l\]: 1 of 1 function bodies built" "$WORK/proj.log" && \
   grep -q "I0003 census \[.*src/b/b.l\]: 0 diagnostic" "$WORK/proj.log"; then
  echo "ok   package_qualified_type_function"
else
  echo "FAIL (package_qualified_type_function)"; grep -E "first error" "$WORK/proj.log" | head -3; fail=1
fi
exit $fail
