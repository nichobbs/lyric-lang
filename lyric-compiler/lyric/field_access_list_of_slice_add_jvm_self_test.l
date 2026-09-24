//! field_access_list_of_slice_add_jvm_self_test.l — regression test for #6957:
//! `List[slice[Elem]].add()` on a FIELD-ACCESS receiver (`c.rows.add(...)`,
//! `self.rows.add(...)`) wasn't covered by #6546's fix (PR #6917,
//! D-progress-879).
//!
//! #6546 intercepts a bare slice-literal argument to `.add()` (`04_calls.l`'s
//! `lowerMethodCall`) whenever the RECEIVER's recorded generic instantiation
//! (`scrutineeGenericArgs`, `03_match.l`) names a `slice[Elem]` element type —
//! without the interception, `[1, 2, 3]` lowers to a `java.util.ArrayList`
//! (every `EList` literal does) instead of a real array, and a later
//! `for row in xs { for v in row { … } }` throws `ClassCastException: class
//! java.util.ArrayList cannot be cast to class [Ljava.lang.Object;`.
//!
//! `scrutineeGenericArgs` only resolved a receiver's generic instantiation
//! for a bare local/parameter reference, an `EList` literal, or specific
//! `ECall` shapes — falling through to `newList()` (no recorded args, so no
//! interception) for a plain FIELD-ACCESS receiver (`someRecord.rows`),
//! reproducing exactly #6546's Bug 1 failure mode for that one shape.
//!
//! Fixed by giving `JvmCaseField` its own `genericArgs` (the field's declared
//! type's own generic instantiation, via the same `returnTypeGenericArgs`
//! helper a function's return type already uses) and adding a top-level
//! `EMember` arm to `scrutineeGenericArgs` that resolves the receiver's class
//! (the same way the existing method-call-receiver resolution already does)
//! and looks the field up in `ctx.caseFields`.
//!
//! Drives the in-process `Jvm.Bridge.compileToJarBundled` pipeline directly
//! (mirroring `jvm_auto_ffi_bridge_self_test.l`) rather than compiling
//! through the OUTER `lyric test` binary's own bundled compiler — a plain
//! `@test_module` importing only `Std.*` is compiled by the CLI's own
//! (possibly stale, prebuilt) compiler, not by this session's freshly-built
//! `Jvm.Codegen`, and would silently validate nothing after a codegen-only
//! change. Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so
//! it can import `Jvm.Bridge` from the pre-compiled stage-1 bundle DLLs,
//! mirroring `jvm_auto_ffi_bridge_self_test.l` / `jvm_cross_package_collision_self_test.l`.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/field_access_list_of_slice_add_jvm_self_test.l
@test_module
package Lyric.FieldAccessListOfSliceAddJvmSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge
import Lyric.Emitter as Emitter

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-field-slice-add-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// Compile `source` (a single package whose entry package name is `stem`) to
// a bundled JAR and run it via `java -jar`, returning captured stdout/stderr.
func compileAndRunSingle(label: in String, stem: in String, source: in String): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val outPath = Path.join(dir, stem + ".jar")
  val stdlibSources = Emitter.findStdlibSourcesJvm()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, stem, stdlibSources, "0.1.0")
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  if panicked {
    cleanup(dir)
    panic(label + ": compileToJarBundled panicked: " + caughtMessage)
  }
  if not ok {
    cleanup(dir)
    panic(label + ": compileToJarBundled returned false")
  }
  val runArgs: List[String] = newList()
  runArgs.add("-jar")
  runArgs.add(outPath)
  val result = Capture.runCaptureWithDiagnostics("java", runArgs, "")
  cleanup(dir)
  result
}

test "a bare slice literal added via a field-access receiver round-trips as a real array (#6957)" {
  val source = "package FieldSliceAdd\n" + "\n" + "import Std.String\n" + "import Std.Core\n" + "\n" +
    "record Container {\n" +
    "  rows: List[slice[Int]]\n" +
    "}\n" +
    "\n" +
    "func sumRows(xs: in List[slice[Int]]): Int {\n" +
    "  var total = 0\n" +
    "  for row in xs {\n" +
    "    for v in row {\n" +
    "      total = total + v\n" +
    "    }\n" +
    "  }\n" +
    "  total\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val c = Container(rows = newList())\n" +
    "  c.rows.add([1, 2, 3])\n" +
    "  println(Std.String.fromInt(c.rows.count))\n" +
    "  println(Std.String.fromInt(sumRows(c.rows)))\n" +
    "  val row = c.rows[0]\n" +
    "  println(Std.String.fromInt(row.length))\n" +
    "  println(Std.String.fromInt(row[0]))\n" +
    "  println(Std.String.fromInt(row[1]))\n" +
    "  println(Std.String.fromInt(row[2]))\n" +
    "}\n"
  val result = compileAndRunSingle("field-recv", "FieldSliceAdd", source)
  assertEqualInt(result.exitCode, 0, "run must succeed (stderr=" + result.stderr + ")")
  val lines = Str.split(Str.trim(result.stdout), "\n")
  assertEqualInt(lines.length, 6, "expected 6 output lines (stdout=" + result.stdout + ")")
  assertEqual(lines[0], "1", "one row was added")
  assertEqual(lines[1], "6", "row sums correctly after round-trip")
  assertEqual(lines[2], "3", "row keeps its real length")
  assertEqual(lines[3], "1", "row[0]")
  assertEqual(lines[4], "2", "row[1]")
  assertEqual(lines[5], "3", "row[2]")
}

test "a bare slice literal added via self.field from an instance method round-trips as a real array (#6957)" {
  val source = "package FieldSliceAddSelf\n" + "\n" + "import Std.String\n" + "import Std.Core\n" + "\n" +
    "record RowAccumulator {\n" +
    "  rows: List[slice[Int]]\n" +
    "  func addRow(self: in RowAccumulator, vals: slice[Int]): Unit {\n" +
    "    self.rows.add(vals)\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val acc = RowAccumulator(rows = newList())\n" +
    "  acc.addRow([4, 5, 6])\n" +
    "  println(Std.String.fromInt(acc.rows.count))\n" +
    "  println(Std.String.fromInt(acc.rows[0][1]))\n" +
    "}\n"
  val result = compileAndRunSingle("self-field-recv", "FieldSliceAddSelf", source)
  assertEqualInt(result.exitCode, 0, "run must succeed (stderr=" + result.stderr + ")")
  val lines = Str.split(Str.trim(result.stdout), "\n")
  assertEqualInt(lines.length, 2, "expected 2 output lines (stdout=" + result.stdout + ")")
  assertEqual(lines[0], "1", "one row was added via self.rows.add")
  assertEqual(lines[1], "5", "nested index acc.rows[0][1]")
}

// #7176 (review finding on this PR): a generic record's field typed as the
// record's OWN generic type parameter (`Box[T] { items: List[T] }`) must not
// leak the unresolved bare `T` into `JvmCaseField.genericArgs` — before the
// fix, `Box.items`'s registered `genericArgs` was unfiltered `[T]`, which
// `resolveConcreteTypeExpr`'s indexed-read narrowing (`b.items[0]`) would
// then feed a `checkcast <pkg>/T` against a nonexistent class
// (`NoClassDefFoundError` at class-load, never a compile error). Fixed by
// threading the record's own generic params through
// `returnTypeGenericArgsFiltered` at every `JvmCaseField` construction site.
// `makeBox` exists only so the type checker can infer `T = Int` for
// `Box(items = startItems)` from a DECLARED RETURN TYPE context (a bare
// `Box[T] { items: List[T] }` — single field, no other field's argument to
// infer `T` from directly — cannot otherwise infer `T` from `items`'s
// argument alone, an unrelated pre-existing inference gap, not part of this
// fix); `readFirst`'s `b: in Box[Int]` PARAMETER is where
// `Jvm.Codegen.recordParamClassOf` (#6691) narrows `b`'s class to the real
// `Box`, so `b.items[0]` reaches `scrutineeGenericArgs`'s `EMember` arm.
test "a generic record field typed as the record's OWN type parameter does not leak a bogus checkcast (#7176)" {
  val source = "package OwnTypeParamField\n" + "\n" + "import Std.String\n" + "import Std.Core\n" + "\n" +
    "record Box[T] {\n" +
    "  items: List[T]\n" +
    "}\n" +
    "\n" +
    "func readFirst(b: in Box[Int]): Int {\n" +
    "  b.items[0]\n" +
    "}\n" +
    "\n" +
    "func makeBox(startItems: List[Int]): Box[Int] {\n" +
    "  Box(items = startItems)\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val startItems: List[Int] = [9]\n" +
    "  val bx: Box[Int] = makeBox(startItems)\n" +
    "  println(Std.String.fromInt(readFirst(bx)))\n" +
    "}\n"
  val result = compileAndRunSingle("own-type-param-field", "OwnTypeParamField", source)
  assertEqualInt(
    result.exitCode,
    0,
    "run must succeed with no NoClassDefFoundError for a phantom 'T' class (stderr=" + result.stderr + ")"
  )
  assertEqual(Str.trim(result.stdout), "9", "b.items[0] reads the real Int element, not a bogus checkcast")
}
