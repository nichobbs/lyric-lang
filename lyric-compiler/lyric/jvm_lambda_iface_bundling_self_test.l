//! jvm_lambda_iface_bundling_self_test.l — regression coverage for #6113: a
//! package whose OWN function signature takes a function-typed parameter, but
//! never itself lowers a lambda LITERAL, must still emit its package-scoped
//! `<Pkg>/Lyric$Lambda` functional-interface class into the bundled JAR.
//!
//! Before the fix, `Jvm.Codegen.codegenPackageWithSigsSeeded` gated the
//! interface's emission purely on `closureAcc.count > 0` — non-empty only
//! when THIS package's own code lowers an `ELambda` literal. A stdlib-style
//! higher-order function like `Std.Core.countWhere(xs, pred: (Int) -> Bool)`
//! declares zero literals of its own (the caller supplies the closure), so
//! its package's interface was never written to the JAR — the first call
//! threw `java.lang.NoClassDefFoundError: Std/Core/Lyric$Lambda` at runtime
//! (confirmed via `lyric run --target jvm lyric-stdlib/tests/core_tests.l`).
//!
//! These tests drive `Jvm.Bridge.compileToJarBundled` in-process and inspect
//! the produced JAR's raw ZIP central directory via `Jvm.ZipReader` — a
//! structural (build-time) check of what the bundler wrote, matching the
//! bug's own framing ("the bundler omits a class") rather than a full `java`
//! run. A full cross-package runtime exercise (package A's higher-order
//! function actually CALLED with package B's closure literal) hits a
//! separate, already-documented JVM ABI gap — cross-package closure passing
//! throws `ClassCastException` because each package's `Lyric$Lambda`
//! interface is a distinct nominal type (see `lyric-jsonrpc/README.md`
//! "Known upstream issues" #3) — so it is deliberately out of scope here;
//! `closure_jvm_self_test.l` covers the (same-package) call-through-a-
//! function-typed-parameter case that already worked before this fix.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so it can
//! import `Jvm.Bridge` / `Jvm.ZipReader` from the pre-compiled stage-1 bundle
//! DLLs, mirroring `jvm_auto_ffi_bridge_self_test.l` / `deflate_zip_self_test.l`.
//! Run on the default (`dotnet`) target — the pipeline under test
//! (`compileToJarBundled`) always emits JVM bytecode regardless of which
//! target this OUTER test binary itself is compiled for. No
//! `LYRIC_LOAD_COMPILER=1` recompile is needed.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/jvm_lambda_iface_bundling_self_test.l
@test_module
package Jvm.LambdaIfaceBundlingSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge
import Jvm.ZipReader

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-lambda-iface-bundling-" + label + "-" + uuidToString(newUuid()))
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

// Compile `source` to a bundled JAR and return the list of ZIP entry names.
func jarEntryNames(dir: in String, stem: in String, source: in String): List[String] {
  val outPath = Path.join(dir, stem + ".jar")
  val noStdlib: List[String] = newList()
  val ok = compileToJarBundled(source, outPath, stem, noStdlib, "")
  assertTrue(ok, "compileToJarBundled(" + stem + "): compilation must succeed")
  val bytes = File.readBytesOrPanic(outPath)
  val entries = readZipEntries(bytes)
  val names: List[String] = newList()
  var i = 0
  while i < entries.count {
    names.add(entries[i].name)
    i = i + 1
  }
  names
}

func containsName(names: in List[String], name: in String): Bool {
  var i = 0
  while i < names.count {
    if names[i] == name {
      return true
    }
    i += 1
  }
  false
}

test "a function-typed parameter with no lambda literal still emits the package's Lyric$Lambda interface (#6113)" {
  val dir = freshTempDir("no-literal")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.NoLiteral\n" + "\n" +
    "pub func countWhereLike(xs: in slice[Int], pred: in (Int) -> Bool): Int {\n" +
    "  var n = 0\n" +
    "  for x in xs {\n" +
    "    if pred(x) {\n" +
    "      n += 1\n" +
    "    }\n" +
    "  }\n" +
    "  return n\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val names = jarEntryNames(dir, "NoLiteral", source)
  assertTrue(
    containsName(names, "Fixture/NoLiteral/Lyric$Lambda.class"),
    "Fixture/NoLiteral/Lyric$Lambda.class must be present even though the package declares no lambda literal"
  )
}

test "a package with a function-typed parameter AND a same-package literal still emits exactly one Lyric$Lambda interface" {
  val dir = freshTempDir("with-literal")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.WithLiteral\n" + "\n" +
    "pub func applyPred(x: in Int, pred: in (Int) -> Bool): Bool {\n" +
    "  pred(x)\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(applyPred(3, { y: Int -> y > 1 }))\n" +
    "}\n"
  val names = jarEntryNames(dir, "WithLiteral", source)
  var ifaceCount = 0
  var i = 0
  while i < names.count {
    if names[i] == "Fixture/WithLiteral/Lyric$Lambda.class" {
      ifaceCount += 1
    }
    i += 1
  }
  assertEqualInt(ifaceCount, 1, "exactly one Lyric$Lambda interface entry, not zero or a duplicate")
}

test "a package with no function type at all never emits a Lyric$Lambda interface" {
  val dir = freshTempDir("no-function-type")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.NoFunctionType\n" + "\n" + "pub func addOne(x: in Int): Int {\n" + "  x + 1\n" + "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(addOne(1))\n" +
    "}\n"
  val names = jarEntryNames(dir, "NoFunctionType", source)
  assertFalse(
    containsName(names, "Fixture/NoFunctionType/Lyric$Lambda.class"),
    "a package with no function-typed signature anywhere must not emit an unused interface class"
  )
}
