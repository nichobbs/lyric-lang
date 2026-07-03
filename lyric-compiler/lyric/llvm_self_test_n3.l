//! llvm_self_test_n3.l — end-to-end self-test for N3.2 interface vtable
//! dispatch on the native (LLVM) backend.  Parses small programs with
//! `interface` / `impl` declarations, lowers them via `codegenNativePackage`
//! + `lowerNativePackage`, clang-compiles against `lyric-rt/build/lyric_rt.a`,
//! runs the binary, and asserts its exit code / stdout.  The ARC cases
//! build with `-fsanitize=address` (LeakSanitizer on), so a leaked or
//! double-released interface box or implementing object fails the run.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_n3.l
@test_module
package Lyric.LlvmSelfTestN3

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_heap_self_test.l): compile source to a native binary
// (optionally under ASan) and run it.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

func findLyricRt(): String {
  var dir = Environment.currentDirectory()
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(Path.join(dir, "lyric-rt"), "build"), "lyric_rt.a")
    if File.fileExists(candidate) {
      return candidate
    }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir {
      return ""
    }
    dir = parent
    hop = hop + 1
  }
  ""
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    var msg = "test source has parse diagnostics:"
    var i = 0
    while i < pr.diagnostics.count {
      msg = msg + " " + pr.diagnostics[i].code
      i = i + 1
    }
    panic(msg)
  }
  val pkg = codegenNativePackage(pr.file, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-n3-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  if sanitize {
    clangArgs.add("-fsanitize=address")
  }
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func compileAndRun(source: in String): RunOutcome {
  compileAndRunWith(source, false)
}

func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

func printlnShim(): String {
  "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Cases.
// ─────────────────────────────────────────────────────────────────────────────
test "interface dispatch: nullary method through an interface-typed param" {
  val src = "package T\n" + "interface Shape {\n  func area(): Int\n}\n" + "record Square {\n  s: Int\n}\n" +
    "impl Shape for Square {\n  func area(): Int {\n    self.s * self.s\n  }\n}\n" +
    "func describe(x: in Shape): Int {\n  x.area()\n}\n" +
    "func main(): Int {\n  describe(Square(s = 6))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 36, "6*6 through Shape.area")
}

test "interface dispatch: method argument is passed to the impl" {
  val src = "package T\n" + "interface Adder {\n  func addTo(x: Int): Int\n}\n" + "record Base {\n  b: Int\n}\n" +
    "impl Adder for Base {\n  func addTo(x: Int): Int {\n    self.b + x\n  }\n}\n" +
    "func run(a: in Adder): Int {\n  a.addTo(5)\n}\n" +
    "func main(): Int {\n  run(Base(b = 37))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "37 + 5 through Adder.addTo")
}

test "interface dispatch: polymorphism selects the right vtable" {
  val src = "package T\n" + "interface Speaker {\n  func speak(): Int\n}\n" + "record Dog {\n  id: Int\n}\n" +
    "record Cat {\n  id: Int\n}\n" +
    "impl Speaker for Dog {\n  func speak(): Int {\n    self.id + 10\n  }\n}\n" +
    "impl Speaker for Cat {\n  func speak(): Int {\n    self.id + 20\n  }\n}\n" +
    "func voice(s: in Speaker): Int {\n  s.speak()\n}\n" +
    "func main(): Int {\n  voice(Dog(id = 1)) + voice(Cat(id = 3))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 34, "Dog(1)->11 + Cat(3)->23")
}

test "interface dispatch: upcast at a return position" {
  val src = "package T\n" + "interface Shape {\n  func area(): Int\n}\n" + "record Sq {\n  s: Int\n}\n" +
    "impl Shape for Sq {\n  func area(): Int {\n    self.s * self.s\n  }\n}\n" +
    "func makeShape(n: in Int): Shape {\n  Sq(s = n)\n}\n" +
    "func main(): Int {\n  val sh = makeShape(7)\n  sh.area()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 49, "7*7 via returned Shape")
}

test "interface dispatch: String-returning method prints" {
  val src = "package T\n" + printlnShim() + "interface Named {\n  func label(): String\n}\n" +
    "record Person {\n  name: String\n}\n" +
    "impl Named for Person {\n  func label(): String {\n    self.name\n  }\n}\n" +
    "func show(n: in Named): Unit {\n  println(n.label())\n}\n" +
    "func main(): Unit {\n  show(Person(name = \"ivy\"))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "String-returning dispatch exit")
  assertEqual(r.stdout, "ivy\n", "String-returning dispatch stdout")
}

// ── ARC: the interface box owns the implementing object (ASan-clean) ──────────
test "interface ARC: box releases its object under ASan" {
  val src = "package T\n" + "interface Named {\n  func first(): String\n}\n" +
    "record Person {\n  name: String\n  tag: String\n}\n" +
    "impl Named for Person {\n  func first(): String {\n    self.name\n  }\n}\n" +
    "func consume(n: in Named): Int {\n  n.first().length\n}\n" +
    "func main(): Int {\n  consume(Person(name = \"abc\", tag = \"xyz\")) - 3\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "no leak / double-free through interface box")
}

test "interface ARC: many upcasts in a loop stay leak-free under ASan" {
  val src = "package T\n" + "interface Counter {\n  func value(): Int\n}\n" + "record Box {\n  n: Int\n}\n" +
    "impl Counter for Box {\n  func value(): Int {\n    self.n\n  }\n}\n" +
    "func total(c: in Counter): Int {\n  c.value()\n}\n" +
    "func main(): Int {\n" +
    "  var sum = 0\n" +
    "  var i = 0\n" +
    "  while i < 50 {\n    sum = sum + total(Box(n = i))\n    i = i + 1\n  }\n" +
    "  sum - 1225\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "50 upcasts leak-free; sum 0..49 == 1225")
}

// A Unit-returning interface method exercises the `void` ABI branch of
// lowerIfaceDispatch (distinct from the value-returning path) (#4901).
test "interface dispatch: Unit-returning method (void ABI)" {
  val src = "package T\n" + printlnShim() + "interface Sink {\n  func emit(): Unit\n}\n" +
    "record Logger {\n  tag: String\n}\n" +
    "impl Sink for Logger {\n  func emit(): Unit {\n    println(self.tag)\n  }\n}\n" +
    "func drive(s: in Sink): Unit {\n  s.emit()\n}\n" +
    "func main(): Unit {\n  drive(Logger(tag = \"tick\"))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "Unit-returning dispatch exit")
  assertEqual(r.stdout, "tick\n", "Unit-returning dispatch side effect")
}

// One record implementing two interfaces verifies the `<recordIr>|<ifaceKey>`
// vtable keying registers and selects two separate vtables (#4902).
test "interface dispatch: one record implementing two interfaces" {
  val src = "package T\n" + "interface Area {\n  func area(): Int\n}\n" +
    "interface Perimeter {\n  func perimeter(): Int\n}\n" +
    "record Rect {\n  w: Int\n  h: Int\n}\n" +
    "impl Area for Rect {\n  func area(): Int {\n    self.w * self.h\n  }\n}\n" +
    "impl Perimeter for Rect {\n  func perimeter(): Int {\n    (self.w + self.h) * 2\n  }\n}\n" +
    "func asArea(a: in Area): Int {\n  a.area()\n}\n" +
    "func asPerimeter(p: in Perimeter): Int {\n  p.perimeter()\n}\n" +
    "func main(): Int {\n  asArea(Rect(w = 4, h = 5)) + asPerimeter(Rect(w = 4, h = 5))\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 38, "area 20 + perimeter 18")
}

// An interface-typed record field exercises the field-position upcast in
// coerceTo (the concrete record is boxed at construction) and stores the box
// as a ref field of the outer record; ASan proves the outer record's dtor
// releases the box, which in turn releases the implementing object (#4917).
test "interface ARC: interface stored in a record field under ASan" {
  val src = "package T\n" + "interface Shape {\n  func area(): Int\n}\n" + "record Circle {\n  r: Int\n}\n" +
    "impl Shape for Circle {\n  func area(): Int {\n    self.r * self.r\n  }\n}\n" +
    "record Holder {\n  shape: Shape\n  label: String\n}\n" +
    "func main(): Int {\n" +
    "  val h = Holder(shape = Circle(r = 7), label = \"c\")\n" +
    "  h.shape.area() - 49\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "field-position upcast + box-as-field leak-free")
}
