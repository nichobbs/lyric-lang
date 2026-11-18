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

# A function with a doc comment, passed by name as a value before its declaration: the item's span
# starts at the doc comment, the signature's at `func`, and the reference must still resolve to the
# function (the builder counted it "a name that is not a local", #8613).
check documented_function_value 9 <<'LYRIC'
package Shapes0
func apply(f: in (Int) -> Int, x: in Int): Int = f(x)

func main(): Int {
  apply(triple, 3)
}

/// Three times `n`.
/// A second line of documentation.
func triple(n: in Int): Int {
  n * 3
}
LYRIC

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
# (a first version of the union rule never finished building, D488) is a covariant conversion node (D524).
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

check covariant_recursive_union_values 3 <<'LYRIC'
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

# A collection of unions used at a collection of the interface-typed unions (D524).  Built and
# verified only: the MSIL backend casts the list at run time and fails (#9171), so it is not run.
check covariant_collection_values "" <<'LYRIC'
package Shapes11b
import Std.Core
import Std.Collections

interface Greeter {
  func greet(self: in Greeter): Int
}

record English { n: Int }

impl Greeter for English {
  func greet(self: in English): Int = self.n
}

func okEnglish(n: in Int): Result[English, String] = Ok(value = English(n = n))

func total(xs: in List[Result[Greeter, String]]): Int {
  var sum = 0
  for r in xs {
    match r {
      case Ok(g) -> {
        sum = sum + g.greet()
      }
      case Err(_) -> {
      }
    }
  }
  sum
}

func main(): Int {
  val xs: List[Result[English, String]] = newList()
  xs.add(okEnglish(2))
  xs.add(okEnglish(3))
  total(xs)
}
LYRIC

# `forall` and `exists` in contract clauses are built as quantifier nodes over their binder locals
# (D525).  A runtime-checked build skips the quantifier conjunct, so the program still runs.
check quantifier_clauses 7 <<'LYRIC'
package Shapes12
import Std.Core

func below(n: in Int): Int
  requires: n > 0 and forall (i: Int) where i > 0 and i < n { i < n }
{
  n - 1
}

func has(n: in Int): Int
  ensures: exists (k: Int) k == n
{
  n
}

func main(): Int = below(5) + has(3)
LYRIC

# The FFI intrinsics the checker types by name (`nativeNullPtr()`, `nativeAddrOf(x)`, the byte
# accessors) are built-in calls (D526).  Built and verified only: the dotnet backend does not lower
# `NativePtr`.
check ffi_intrinsics "" <<'LYRIC'
package Shapes13
import Std.Core

@unsafe_ffi
func nothing(): NativePtr[Byte] {
  nativeNullPtr()
}

@unsafe_ffi
func touch(): Int {
  val p = nativeNullPtr()
  nativeStoreByte(p, 0, 7u8)
  nativeLoadByte(p, 0).toInt()
}

func main(): Int = 0
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

# Arithmetic on a record that derives Add builds as its fields' operator in a record built from them,
# never as a plain `+` on two records (D422); the program is also run.
check record_arith 1 <<'LYRIC'
package Shapes16
import Std.Core

@derive(Add)
record Vec2 {
  x: Float
  y: Float
}

func sum(): Float {
  val a = Vec2(x = 0.25, y = 1.0)
  val b = Vec2(x = 0.5, y = 2.0)
  var c = a + b
  c += a
  c.x + c.y
}

func main(): Int = if sum() > 3.0 { 1 } else { 0 }
LYRIC

check host_compound_write 6 <<'LYRIC'
package Shapes12
extern type SB = "System.Text.StringBuilder"

func grow(sb: in SB): Unit {
  sb.Length += 3
}

func main(): Int {
  val sb = SB.new()
  grow(sb)
  grow(sb)
  sb.Length
}
LYRIC

# The TIR builds a write to a public host field (D478); the MSIL emitter does not lower one yet
# (T0120), so the program is judged by the census alone and not run.
check host_field_write "" <<'LYRIC'
package Shapes13
extern type Sla = "System.Runtime.InteropServices.StructLayoutAttribute"

func pack(a: in Sla): Unit {
  a.Pack = 4
}

func main(): Int = 0
LYRIC



# A bare case name two enums share (`On` of `Beam` and `Ray`), read where the expected type decides
# which enum it is, builds as that enum's case (D446).
check shared_enum_case 11 <<'LYRIC'
package Shapes16

enum Beam {
  case Off
  case On
}

enum Ray {
  case On
  case Idle
}

func beamOn(): Beam {
  On
}

func rayOn(): Ray {
  On
}

func main(): Int {
  val b = match beamOn() {
    case Beam.On -> 5
    case Beam.Off -> 0
  }
  val r = match rayOn() {
    case Ray.On -> 6
    case Ray.Idle -> 0
  }
  b + r
}
LYRIC

# The same for a nullary case of two unions (`Idle` of `Job` and `Lane`): the expected type decides
# which union it is (D446).
check shared_union_case 11 <<'LYRIC'
package Shapes17

union Job {
  case Idle
  case Run(n: Int)
}

union Lane {
  case Idle
  case Closed
}

func idleJob(): Job {
  Idle
}

func idleLane(): Lane {
  Idle
}

func main(): Int {
  val j = match idleJob() {
    case Job.Idle -> 5
    case Job.Run(n) -> n
  }
  val l = match idleLane() {
    case Lane.Idle -> 6
    case Lane.Closed -> 0
  }
  j + l
}
LYRIC

# A field of a generic record read inside a function generic over the record's parameter keeps its
# type (`List[D]` for `many: List[D]`), so the read and a loop over it build (D492).
check rigid_nested_field 9 <<'LYRIC'
package Shapes15
import Std.Core
import Std.Collections

record A[D] {
  one: D
  many: List[D]
}

func first[D](a: in A[D]): D = a.one

func rest[D](a: in A[D]): List[D] = a.many

func countOf[D](a: in A[D]): Int {
  var n = 0
  for x in a.many {
    n = n + 1
  }
  n
}

func main(): Int {
  val xs: List[Int] = newList()
  xs.add(4)
  xs.add(5)
  val a = A(one = 3, many = xs)
  first(a) + rest(a).count + countOf(a) + 2
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
# A list literal given where a `List[T]` is wanted (a generic record's field, a map's value) builds as that
# `List`, and `newList()` passed to a map's `add` takes the map's value type (D426); the program is run.
check list_literal_arguments 7 <<'LYRIC'
package Shapes17
import Std.Collections

record GBox[T] {
  items: List[T]
}

func boxOf[T](x: in T): GBox[T] {
  GBox(items = [x, x])
}

func imports(): Map[String, List[String]] {
  val m: Map[String, List[String]] = newMap()
  m.add("a", ["b"])
  m.add("c", newList())
  m
}

func main(): Int {
  boxOf(3).items[1] + imports().count + 2
}
LYRIC
# A case name two enums of another package share, read through the package where the annotated type
# decides which enum it is (`val b: Lib.Beam = Lib.On`), builds as that enum's case (D423).
mkdir -p "$WORK/shared/src/lib" "$WORK/shared/src/app"
cat > "$WORK/shared/lyric.toml" <<'TOML'
[package]
name = "SharedCase"
version = "0.1.0"

[project]
name = "SharedCase"
output = "single"
output_assembly = "SharedCase.dll"

[project.packages]
"SiblingEnums" = "src/lib"
"SiblingEnumsValueApp" = "src/app"
TOML
cat > "$WORK/shared/src/lib/lib.l" <<'LYRIC'
package SiblingEnums

pub enum Beam {
  case Off
  case On
}

pub enum Ray {
  case On
  case Idle
}
LYRIC
cat > "$WORK/shared/src/app/app.l" <<'LYRIC'
package SiblingEnumsValueApp
import SiblingEnums

pub func main(): Int {
  val beam: SiblingEnums.Beam = SiblingEnums.On
  val ray: SiblingEnums.Ray = SiblingEnums.On
  match beam {
    case SiblingEnums.On -> 1
    case SiblingEnums.Off -> 0
  }
}
LYRIC
(cd "$WORK/shared" && "$LYRIC" build --verify-ir --manifest lyric.toml --target dotnet >"$WORK/shared.log" 2>&1)
if grep -q "TIR build census \[.*src/app/app.l\]: 1 of 1 function bodies built" "$WORK/shared.log" && \
   grep -q "I0003 census \[.*src/app/app.l\]: 0 diagnostic" "$WORK/shared.log"; then
  echo "ok   package_qualified_shared_enum_case"
else
  echo "FAIL (package_qualified_shared_enum_case)"; grep -E "first error" "$WORK/shared.log" | head -3; fail=1
fi
# A function of another package used as a value through its alias (`AL.update`), its full package path
# (`Reg.Lib.update`) or an import of the name builds as that function's reference (D424).
mkdir -p "$WORK/fnval/src/lib" "$WORK/fnval/src/app"
cat > "$WORK/fnval/lyric.toml" <<'TOML'
[package]
name = "FnVal"
version = "0.1.0"

[project]
name = "FnVal"
output = "single"
output_assembly = "FnVal.dll"

[project.packages]
"Reg.Lib" = "src/lib"
"Reg.App" = "src/app"
TOML
cat > "$WORK/fnval/src/lib/lib.l" <<'LYRIC'
package Reg.Lib

pub func update(x: in Int): Int = x + 1

pub record Prog[M] {
  step: (M) -> M
}

pub func apply[M](p: in Prog[M], m: in M): M = p.step(m)
LYRIC
cat > "$WORK/fnval/src/app/app.l" <<'LYRIC'
package Reg.App
import Reg.Lib as AL
import Reg.Lib.{Prog, apply, update}

pub func main(): Int {
  val pa = Prog(step = AL.update)
  val f: (Int) -> Int = Reg.Lib.update
  val g: (Int) -> Int = update
  val h: (Int) -> Int = AL.update
  apply(pa, 1) + f(1) + g(1) + h(1)
}
LYRIC
(cd "$WORK/fnval" && "$LYRIC" build --verify-ir --manifest lyric.toml --target dotnet >"$WORK/fnval.log" 2>&1)
if grep -q "TIR build census \[.*src/app/app.l\]: 1 of 1 function bodies built" "$WORK/fnval.log" && \
   grep -q "I0003 census \[.*src/app/app.l\]: 0 diagnostic" "$WORK/fnval.log"; then
  echo "ok   package_qualified_function_value"
else
  echo "FAIL (package_qualified_function_value)"; grep -E "first error" "$WORK/fnval.log" | head -3; fail=1
fi
# A host call chain whose middle result is a host class no `extern type` names, built for the JVM
# (D444): `m.entrySet().iterator()` is typed from the host metadata.  The program is also run.
cat > "$WORK/jvm_host_chain.l" <<'LYRIC'
package JvmHostChain
extern type HM = "java.util.HashMap"
extern type It = "java.util.Iterator"

func hasEntries(m: in HM): Bool {
  val it: It = m.entrySet().iterator()
  it.hasNext()
}

func main(): Int {
  val m: HM = HM.new()
  if hasEntries(m) { 1 } else { 0 }
}
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_chain.l" -o "$WORK/jvm_host_chain.jar" >"$WORK/jvm_host_chain.log" 2>&1)
jline="$(grep "^TIR build census" "$WORK/jvm_host_chain.log" | head -1)"
if [[ -z "$jline" || "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$jline")" != "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$jline")" ]]; then
  echo "FAIL (jvm_host_chain): not every body built"; grep -E "first error" "$WORK/jvm_host_chain.log" | head -3; fail=1
elif ! grep -q "^I0003 census .*: 0 diagnostic" "$WORK/jvm_host_chain.log"; then
  echo "FAIL (jvm_host_chain): the verifier rejected a built body"; fail=1
else
  (cd "$WORK" && java -jar jvm_host_chain.jar >/dev/null 2>&1); got=$?
  if [[ "$got" != "0" ]]; then echo "FAIL (jvm_host_chain): exit code $got, want 0"; fail=1; else echo "ok   jvm_host_chain"; fi
fi
# A host array result (`readAllBytes()`) is the checker's slice, not a plain host class, so a chain on a
# host value does not type it as the host array (D444): the verifier must report nothing.
cat > "$WORK/jvm_host_array_result.l" <<'LYRIC'
package JvmHostArrayResult
extern type JFIS = "java.io.FileInputStream"

func readAll(path: in String): slice[Byte] {
  val fis = JFIS.new(path)
  try {
    val all = fis.readAllBytes()
    fis.close()
    all
  } catch Bug as b {
    fis.close()
    panic(b.message)
  }
}

func main(): Int { 0 }
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_array_result.l" -o "$WORK/jvm_host_array_result.jar" >"$WORK/jvm_host_array_result.log" 2>&1)
if ! grep -q "^I0003 census \[.*jvm_host_array_result.l\]: 0 diagnostic" "$WORK/jvm_host_array_result.log"; then
  echo "FAIL (jvm_host_array_result): the verifier rejected a built body"; grep "I0003" "$WORK/jvm_host_array_result.log" | head -3; fail=1
else
  echo "ok   jvm_host_array_result"
fi
# An untyped host array result of host objects (`HashSet.toArray()`) returned as the slice of a type
# parameter (the JVM kernel's `setToSlice`): the erased arrays share a representation, so it is a
# `CvFromHost` conversion the verifier accepts.
cat > "$WORK/jvm_host_array_erased.l" <<'LYRIC'
package JvmHostArrayErased
extern type JSet = "java.util.HashSet"

func snapshot[T](s: in JSet): slice[T] {
  s.toArray()
}

func main(): Int {
  val s: JSet = JSet.new()
  val xs: slice[String] = snapshot[String](s)
  xs.length
}
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_array_erased.l" -o "$WORK/jvm_host_array_erased.jar" >"$WORK/jvm_host_array_erased.log" 2>&1)
eline="$(grep "^TIR build census" "$WORK/jvm_host_array_erased.log" | head -1)"
if [[ -z "$eline" || "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$eline")" != "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$eline")" ]] || \
   ! grep -q "^I0003 census \[.*jvm_host_array_erased.l\]: 0 diagnostic" "$WORK/jvm_host_array_erased.log"; then
  echo "FAIL (jvm_host_array_erased): not every body built, or the verifier rejected one"; grep -E "first error|I0003" "$WORK/jvm_host_array_erased.log" | head -3; fail=1
else
  echo "ok   jvm_host_array_erased"
fi
# The host expressions the checker leaves untyped (docs/01 section 2.11), each typed by the builder from the
# host's metadata (D445): a static field read on an extern type, a static call whose result is the next
# call's receiver, a host call's string result as `String?`, a call of a host member on a value of a type
# parameter's type, and `Method.invoke`'s root-object result.  Every body must build, the verifier must
# accept it, and the program must run.
cat > "$WORK/jvm_host_static_shapes.l" <<'LYRIC'
package JvmHostStaticShapes
extern type JCharacter = "java.lang.Character"
extern type JClass = "java.lang.Class"
extern type JMethod = "java.lang.reflect.Method"
extern type JObject = "java.lang.Object"

func primitiveChar(): JClass {
  val c: JClass = JCharacter.TYPE
  c
}

func nameViaStaticChain(): Bool {
  val n = JClass.forName("java.lang.String").getName()
  n == "java.lang.String"
}

func classOf[A](x: in A): JClass {
  val c: JClass = x.getClass()
  c
}

func methodName(m: in JMethod): Bool {
  m.getName() == "length"
}

extern type JArrayList = "java.util.ArrayList"
extern type JKeyStore = "java.security.KeyStore"

// A host call's string passed for a host string parameter: `getDefaultType()` is `String?`.
func defaultKeyStoreType(): JKeyStore {
  JKeyStore.getInstance(JKeyStore.getDefaultType())
}

// An untyped host array result (`toArray()`) passed on as a slice.
func arrayOf(l: in JArrayList): slice[JObject] {
  l.toArray()
}

func main(): Int {
  if defaultKeyStoreType().getType() != JKeyStore.getDefaultType() {
    return 4
  }
  if arrayOf(JArrayList.new()).length != 0 {
    return 5
  }
  if primitiveChar().getName() != "char" {
    return 1
  }
  if not nameViaStaticChain() {
    return 2
  }
  if classOf("s").getName() != "java.lang.String" {
    return 3
  }
  0
}
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_static_shapes.l" -o "$WORK/jvm_host_static_shapes.jar" >"$WORK/jvm_host_static_shapes.log" 2>&1)
sline="$(grep "^TIR build census \[.*jvm_host_static_shapes.l\]" "$WORK/jvm_host_static_shapes.log" | head -1)"
if [[ -z "$sline" || "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$sline")" != "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$sline")" ]]; then
  echo "FAIL (jvm_host_static_shapes): not every body built"; grep -E "first error" "$WORK/jvm_host_static_shapes.log" | head -3; fail=1
elif ! grep -q "^I0003 census \[.*jvm_host_static_shapes.l\]: 0 diagnostic" "$WORK/jvm_host_static_shapes.log"; then
  echo "FAIL (jvm_host_static_shapes): the verifier rejected a built body"; fail=1
else
  (cd "$WORK" && java -jar jvm_host_static_shapes.jar >/dev/null 2>&1); got=$?
  if [[ "$got" != "0" ]]; then echo "FAIL (jvm_host_static_shapes): exit code $got, want 0"; fail=1; else echo "ok   jvm_host_static_shapes"; fi
fi
# A call on a restored package's concrete type takes the default of the `impl` method it resolves to,
# not the interface's (language reference 6.1): the interface carries a declaration for each non-generic
# `impl` member that declares a default (D447).  Two types implement the same interface method (the language
# rejects two impls of one type that share a method name, T0139), each with its own default: 4 * 3, 5 * 7 and an
# explicit 5 * 2 add to 57, on both targets.
restored_impl_defaults() {
  local target="$1" dir="$WORK/impldef-$1"
  mkdir -p "$dir/lib/src" "$dir/app/src"
  cat > "$dir/lib/lyric.toml" <<'TOML'
[package]
name = "Id.Lib"
version = "0.1.0"

[project]
name = "Id.Lib"
output = "single"
output_assembly = "IdLib.dll"

[project.packages]
"IdLib" = "src/lib.l"
TOML
  cat > "$dir/lib/src/lib.l" <<'LYRIC'
package IdLib

pub interface Shape {
  func area(self: in Self, scale: in Int = 1): Int
}

pub record Sq {
  s: Int
}

pub record Circle {
  r: Int
}

impl Shape for Sq {
  func area(self: in Sq, scale: in Int = 3): Int {
    self.s * scale
  }
}

impl Shape for Circle {
  func area(self: in Circle, scale: in Int = 7): Int {
    self.r * scale
  }
}
LYRIC
  cat > "$dir/app/lyric.toml" <<'TOML'
[package]
name = "Id.App"
version = "0.1.0"

[dependencies]
"Id.Lib" = { path = "../lib" }

[project]
name = "Id.App"
output = "single"
output_assembly = "IdApp.dll"

[project.packages]
"IdApp" = "src/app.l"
TOML
  cat > "$dir/app/src/app.l" <<'LYRIC'
package IdApp
import IdLib

func main(): Int {
  val q = Sq(s = 4)
  val c = Circle(r = 5)
  q.area() + c.area() + c.area(2)
}
LYRIC
  (cd "$dir" && "$LYRIC" build --manifest "$dir/lib/lyric.toml" --target "$target" >"$dir/lib.log" 2>&1) || { echo "FAIL (restored_impl_defaults $target): the library did not build"; tail -3 "$dir/lib.log"; fail=1; return; }
  (cd "$dir" && "$LYRIC" build --verify-ir --manifest "$dir/app/lyric.toml" --target "$target" >"$dir/app.log" 2>&1) || { echo "FAIL (restored_impl_defaults $target): the consumer did not build"; tail -3 "$dir/app.log"; fail=1; return; }
  local line built total
  line="$(grep "^TIR build census \[.*app.l\]" "$dir/app.log" | head -1)"
  built="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$line")"
  total="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$line")"
  if [[ -z "$line" || "$built" != "$total" ]]; then
    echo "FAIL (restored_impl_defaults $target): $built of $total consumer bodies built"; grep -E "first error" "$dir/app.log" | head -3; fail=1; return
  fi
  if ! grep -q "^I0003 census \[.*app.l\]: 0 diagnostic" "$dir/app.log"; then
    echo "FAIL (restored_impl_defaults $target): the verifier rejected a built body"; fail=1; return
  fi
  local got
  (cd "$dir" && "$LYRIC" run --manifest "$dir/app/lyric.toml" --target "$target" >/dev/null 2>&1); got=$?
  if [[ "$got" != "57" ]]; then echo "FAIL (restored_impl_defaults $target): exit code $got, want 57"; fail=1; return; fi
  echo "ok   restored_impl_defaults $target"
}
restored_impl_defaults dotnet
restored_impl_defaults jvm

# Host chains the builder does not type stay counted and the verifier reports nothing: a chain on a
# result that is a Lyric value (a string, a boxed number), and a member the host class has no overload
# for.  The JVM build must finish and every body that builds must verify (D444, D445).
cat > "$WORK/jvm_host_chain_counted.l" <<'LYRIC'
package JvmHostChainCounted
extern type JString = "java.lang.String"
extern type JInteger = "java.lang.Integer"
extern type JArrayList = "java.util.ArrayList"

func lengthOfValue(): Int {
  JString.valueOf(12345).length()
}

func boxedHash(): Int {
  JInteger.valueOf(7).hashCode()
}

func firstOfEmpty(): Int {
  val l: JArrayList = JArrayList.new()
  l.toArray().length
}

func main(): Int { 0 }
LYRIC
(cd "$WORK" && timeout 600 "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_chain_counted.l" -o "$WORK/jvm_host_chain_counted.jar" >"$WORK/jvm_host_chain_counted.log" 2>&1)
if ! grep -q "^I0003 census \[.*jvm_host_chain_counted.l\]: 0 diagnostic" "$WORK/jvm_host_chain_counted.log"; then
  echo "FAIL (jvm_host_chain_counted): the verifier rejected a built body or the build did not finish"; grep "I0003" "$WORK/jvm_host_chain_counted.log" | head -3; fail=1
else
  echo "ok   jvm_host_chain_counted"
fi
# A call on a generic host class applied to the function's own type parameters (`HashMap<K, V>.get`,
# the JVM kernel's `tryGetValue`): the checker records no type for the host's erased `Object` result, so
# the builder types it as the host `Object` and converts it where `V` is wanted.  Every function must build
# and the verifier must accept it.
cat > "$WORK/jvm_host_generic_result.l" <<'LYRIC'
package JvmHostGenericResult
extern type JMap[K, V] = "java.util.HashMap"

func tryGet[K, V](m: in JMap[K, V], key: in K, value: out V): Bool {
  value = m.get(key)
  m.containsKey(key)
}

func main(): Int { 0 }
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_generic_result.l" -o "$WORK/jvm_host_generic_result.jar" >"$WORK/jvm_host_generic_result.log" 2>&1)
gline="$(grep "^TIR build census \[.*jvm_host_generic_result.l\]" "$WORK/jvm_host_generic_result.log" | head -1)"
if [[ -z "$gline" || "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$gline")" != "$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$gline")" ]] || \
   ! grep -q "^I0003 census \[.*jvm_host_generic_result.l\]: 0 diagnostic" "$WORK/jvm_host_generic_result.log"; then
  echo "FAIL (jvm_host_generic_result): not every body built, or the verifier rejected one"; grep -E "first error|I0003" "$WORK/jvm_host_generic_result.log" | head -3; fail=1
else
  echo "ok   jvm_host_generic_result"
fi
# A local bound to a host result the checker leaves unchecked (`val v = m.computeIfAbsent(..)`, the host's
# `Object`) and read where a `String` is wanted: the read converts with `CvFromHost`, so the local's type
# and the read agree and the verifier accepts it (the I0003 `local-type` rule).
cat > "$WORK/jvm_host_local_read.l" <<'LYRIC'
package JvmHostLocalRead
extern type JHashMap = "java.util.HashMap"

func lookup(): String {
  val prefix = "v:"
  val m = JHashMap.new()
  val v = m.computeIfAbsent("key", { k: String -> prefix + k })
  v
}

func main(): Int { 0 }
LYRIC
(cd "$WORK" && "$LYRIC" build --verify-ir --target jvm "$WORK/jvm_host_local_read.l" -o "$WORK/jvm_host_local_read.jar" >"$WORK/jvm_host_local_read.log" 2>&1)
if ! grep -q "^I0003 census \[.*jvm_host_local_read.l\]: 0 diagnostic" "$WORK/jvm_host_local_read.log"; then
  echo "FAIL (jvm_host_local_read): the verifier rejected a built body"; grep "I0003" "$WORK/jvm_host_local_read.log" | head -3; fail=1
else
  echo "ok   jvm_host_local_read"
fi

# A record and a function reached through an alias of a package that re-exports them (`pub use`):
# `L.Leaf(v = n)` and `L.ident(4)` have recorded callees (D420).
reexport_qualified() {
  local dir="$WORK/reexport_qualified"
  mkdir -p "$dir/src"
  cat > "$dir/lyric.toml" <<'TOML'
[package]
name    = "Fac"
version = "0.1.0"

[project]
name            = "Fac"
output          = "single"
output_assembly = "Fac.dll"

[project.packages]
"Pu.Inner" = "src/inner.l"
"Pu" = "src/pu.l"
"Pu.Main" = "src/main.l"
TOML
  cat > "$dir/src/inner.l" <<'LYRIC'
package Pu.Inner

pub record Leaf {
  v: Int
}

pub func ident(n: in Int): Int = n
LYRIC
  cat > "$dir/src/pu.l" <<'LYRIC'
package Pu

import Pu.Inner
pub use Pu.Inner

pub func own(): Int = 1
LYRIC
  cat > "$dir/src/main.l" <<'LYRIC'
package Pu.Main

import Pu as L

func leafOf(n: in Int): L.Leaf {
  L.Leaf(v = n)
}

func main(): Int {
  val a = L.ident(4)
  val b = leafOf(5).v
  a + b
}
LYRIC
  (cd "$dir" && "$LYRIC" build --verify-ir --manifest "$dir/lyric.toml" >"$dir/build.log" 2>&1) || { echo "FAIL (reexport_qualified): the project did not build"; tail -3 "$dir/build.log"; fail=1; return; }
  local line built total
  line="$(grep "^TIR build census \[.*main.l\]" "$dir/build.log" | head -1)"
  built="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$line")"
  total="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$line")"
  if [[ -z "$line" || "$built" != "$total" ]]; then
    echo "FAIL (reexport_qualified): $built of $total bodies built"; grep -E "first error" "$dir/build.log" | head -3; fail=1; return
  fi
  if ! grep -q "^I0003 census \[.*main.l\]: 0 diagnostic" "$dir/build.log"; then
    echo "FAIL (reexport_qualified): the verifier rejected a built body"; fail=1; return
  fi
  echo "ok   reexport_qualified"
}
reexport_qualified

# `b.withMutPointer(f)` on a buffer and `w.upgrade()` on a `NativeWeak` have no declared callee: the
# checker records them as built-in calls by name (D421).  Native only, so built for native.
native_member_intrinsics() {
  local src="$WORK/native_member_intrinsics.l" log="$WORK/native_member_intrinsics.log"
  cat > "$src" <<'LYRIC'
package App

import Std.Core

extern func cMemset(p: NativePtr[Byte], c: Int, n: Long): NativePtr[Byte] = "memset"

record Node {
  name: String
}

@unsafe_ffi
func fillSeven(b: inout buffer[Byte]): Unit {
  val _ = b.withMutPointer({ p: NativePtr[Byte] ->
    val _ = cMemset(p, 7, 4)
    0
  })
}

func lengthOf(w: in NativeWeak[Node]): Int {
  match w.upgrade() {
    case Some(n) -> n.name.length
    case None -> 0
  }
}

func main(): Int = 0
LYRIC
  (cd "$WORK" && "$LYRIC" build --verify-ir --target native "$src" -o "$WORK/native_member_intrinsics" >"$log" 2>&1)
  local line built total
  line="$(grep "^TIR build census" "$log" | head -1)"
  built="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\1/' <<<"$line")"
  total="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function.*/\2/' <<<"$line")"
  if [[ -z "$line" || "$built" != "$total" ]]; then
    echo "FAIL (native_member_intrinsics): $built of $total bodies built"; grep -E "first error" "$log" | head -3; fail=1; return
  fi
  if ! grep -q "^I0003 census .*: 0 diagnostic" "$log"; then
    echo "FAIL (native_member_intrinsics): the verifier rejected a built body"; grep "I0003" "$log" | head -3; fail=1; return
  fi
  echo "ok   native_member_intrinsics"
}
native_member_intrinsics

exit $fail
