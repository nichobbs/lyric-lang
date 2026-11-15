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

# check_counted NAME <<< source: the program must reach the end of the build (a hang is the failure
# this guards against) and the verifier must report nothing, but a body may stay counted.
check_counted() {
  local name="$1" src="$WORK/$1.l" log="$WORK/$1.log"
  cat > "$src"
  (cd "$WORK" && timeout 180 "$LYRIC" build --verify-ir "$src" -o "$WORK/$name.dll" >"$log" 2>&1)
  local rc=$?
  if [[ $rc -eq 124 ]]; then echo "FAIL ($name): the build did not finish in 180s"; fail=1; return; fi
  if ! grep -q "^TIR build census" "$log" || ! grep -q "^I0003 census .*: 0 diagnostic" "$log"; then
    echo "FAIL ($name): no census, or the verifier rejected a built body"; grep -E "I0003|error" "$log" | head -3; fail=1; return
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

# Calls with open type arguments inside a call with open type arguments (each takes its own parameter types).
check nested_open_calls 2 <<'LYRIC'
package Shapes5
import Std.Core
import Std.Collections

func both[T](a: in List[T], b: in List[T]): List[T] {
  val r: List[T] = newList()
  r
}

func main(): Int {
  val xs: List[Int] = both(both(newList(), newList()), both(newList(), newList()))
  xs.add(1)
  xs.add(2)
  xs.count
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

# A record method beside a dot-named function of another arity (#9106, #8098): each call takes its own.
check method_beside_dot_named 174 <<'LYRIC'
package Shapes4
import Std.Core

record Oe {
  n: Int
  func m(self: in Oe, x: in Int, y: in Int): Int {
    80 + x + y
  }
}

func Oe.m(o: in Oe, x: in Int): Int {
  90 + x
}

func main(): Int {
  val e = Oe(n = 0)
  e.m(1) + e.m(1, 2)
}
LYRIC

# Defaults a source-loaded package declares as a bare case (`Tls12`, `None`): each is the case of the
# field's own union or enum (D485).
check stdlib_case_defaults 0 <<'LYRIC'
package Shapes7
import Std.Core
import Std.Tls

func minOf(c: in TlsServerConfig): Int {
  match c.minVersion {
    case Tls12 -> 0
    case Tls13 -> 1
  }
}

func main(): Int {
  match Identity.fromPem("a", "b") {
    case Ok(id) -> {
      val c = TlsServerConfig(identity = id)
      val none = match c.clientCa { case None -> 0; case Some(_) -> 1 }
      minOf(c) + none
    }
    case Err(_) -> 0
  }
}
LYRIC

# A binding whose initializer leaves a type argument open takes the type its uses fix, and a name a
# pattern then binds from it is a local (D486).
check open_binding_uses 8 <<'LYRIC'
package Shapes8
import Std.Core

func viaAlias(): Int {
  val o = None
  val o2 = o
  val x: Option[Int] = o2
  match o {
    case Some(v) -> v
    case None -> 3
  }
}

func tupled(): Int {
  val t = (None, 5)
  match t {
    case (o, n) -> addOpt(o, n)
  }
}

func addOpt(o: in Option[Int], n: in Int): Int {
  match o {
    case Some(v) -> v + n
    case None -> n
  }
}

func main(): Int = viaAlias() + tupled()
LYRIC

# A union value used at the same union with other type arguments (`Result[English, String]` where a
# `Result[Greeter, String]` is wanted) as an argument, a tail expression and an annotated binding (D487).
check covariant_union_values 30 <<'LYRIC'
package Shapes9
import Std.Core

interface Greeter {
  func greet(self: in Greeter): Int
}

record English { n: Int }

impl Greeter for English {
  func greet(self: in English): Int = self.n
}

func okEnglish(n: in Int): Result[English, String] = Ok(value = English(n = n))

func describe(r: in Result[Greeter, String]): Int {
  match r {
    case Ok(g) -> g.greet()
    case Err(_) -> 0
  }
}

func viaArgument(n: in Int): Int = describe(okEnglish(n))

func viaTail(n: in Int): Result[Greeter, String] = okEnglish(n)

func viaBinding(): Int {
  val r: Result[Greeter, String] = okEnglish(5)
  describe(r)
}

func main(): Int = viaArgument(10) + describe(viaTail(7)) + viaBinding() + 8
LYRIC

# A generic record value used at the same record with other type arguments, and a recursive union
# whose conversion stays counted (a first version of the union rule never finished building) (D488).
check covariant_record_values 17 <<'LYRIC'
package Shapes10
import Std.Core

interface Greeter {
  func greet(self: in Greeter): Int
}

record English { n: Int }

impl Greeter for English {
  func greet(self: in English): Int = self.n
}

record Box[T] { item: T, tag: Int }

func boxed(n: in Int): Box[English] = Box(item = English(n = n), tag = 2)

func open(b: in Box[Greeter]): Int = b.item.greet() + b.tag

func viaArgument(n: in Int): Int = open(boxed(n))

func viaBinding(): Int {
  val b: Box[Greeter] = boxed(4)
  open(b)
}

func main(): Int = viaArgument(5) + viaBinding() + 4
LYRIC

check_counted covariant_recursive_union_stays_counted <<'LYRIC'
package Shapes11
import Std.Core

interface Greeter {
  func greet(self: in Greeter): Int
}

record English { n: Int }

impl Greeter for English {
  func greet(self: in English): Int = self.n
}

union Tree[T] {
  case Leaf(value: T)
  case Node(left: Tree[T], right: Tree[T])
}

func leaf(n: in Int): Tree[English] = Leaf(value = English(n = n))

func widen(t: in Tree[English]): Tree[Greeter] = t

func main(): Int {
  match widen(leaf(3)) {
    case Leaf(g) -> g.greet()
    case Node(_, _) -> 0
  }
}
LYRIC

# An array with no initializer is its zero value, and an array stored from a place is a copy (D489).
check array_copy_and_zero 27 <<'LYRIC'
package Shapes12
import Std.Core

record Grid {
  cells: array[3, Int]
}

func sumOf(a: in array[3, Int]): Int = a[0] + a[1] + a[2]

func filled(): array[3, Int] {
  var a: array[3, Int]
  a[0] = 4
  a[1] = 5
  a
}

func main(): Int {
  val a = filled()
  var b = a
  b[2] = 9
  val g = Grid(cells = b)
  var zero: array[3, Int]
  sumOf(a) + sumOf(g.cells) + sumOf(zero)
}
LYRIC

# The operand of `?` that is a construction leaving a type argument open takes its success type from
# its payload and its error type from the enclosing function (D490).
check propagate_open_operand 7 <<'LYRIC'
package Shapes13
import Std.Core

func okInit(): Result[Int, String] {
  val m = Ok(value = "bb")?
  Ok(value = m.length)
}

func someInit(): Option[Int] {
  val s = Some(value = "abc")?
  Some(value = s.length)
}

func main(): Int {
  val a = match okInit() { case Ok(v) -> v; case Err(_) -> 100 }
  val b = match someInit() { case Some(v) -> v; case None -> 100 }
  a + b + 2
}
LYRIC

# A float literal passed where a `Float` is expected is a `Float` literal, not a conversion (D491).
check float_literal_argument 5 <<'LYRIC'
package Shapes14
import Std.Core

func half(x: in Float): Float = x

func main(): Int {
  val h = half(0.5)
  if h > 0.25 and half(2.0) > 1.5 { 5 } else { 0 }
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
