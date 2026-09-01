//! jvm_lambda_iface_bundling_self_test.l — regression coverage for #6113: a
//! package whose OWN function signature takes a function-typed parameter, but
//! never itself lowers a lambda LITERAL, must still emit the shared
//! `Lyric/Lyric$Lambda` functional-interface class into the bundled JAR.
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
//! Most of these tests drive `Jvm.Bridge.compileToJarBundled` in-process and
//! inspect the produced JAR's raw ZIP central directory via `Jvm.ZipReader`
//! — a structural (build-time) check of what the bundler wrote, matching the
//! bug's own framing ("the bundler omits a class") rather than a full `java`
//! run.
//!
//! The interface's binary name is now shared across every package in a
//! bundle (`Lyric/Lyric$Lambda`, fixed in #5388/#5251) rather than
//! per-package (`<Pkg>/Lyric$Lambda`) — a closure literal written in package
//! A and invoked through a function-typed parameter in package B used to
//! `checkcast` against B's OWN, nominally-distinct interface and fail with
//! `ClassCastException: class A$Lambda$0 cannot be cast to class
//! B.Lyric$Lambda` (see `lyric-jsonrpc/README.md`'s formerly-listed "Known
//! upstream issues" #3, and `Std.Testing.assertPanicsWith`'s lambda-argument
//! form, which hit this on EVERY call since the test file and `Std.Testing`
//! are always different packages). The last test below drives the full
//! multi-package project bridge (`compileProjectToJarBundledWithFeatures`)
//! and runs the resulting JAR under `java`, proving the cross-package call
//! actually works end to end now, not just that one interface entry exists.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so it can
//! import `Jvm.Bridge` / `Jvm.ZipReader` from the pre-compiled stage-1 bundle
//! DLLs, mirroring `jvm_auto_ffi_bridge_self_test.l` / `deflate_zip_self_test.l`.
//! Run on the default (`dotnet`) target — the pipeline under test
//! (`compileToJarBundled` / `compileProjectToJarBundledWithFeatures`) always
//! emits JVM bytecode (and the last test's `java -jar` run genuinely executes
//! it) regardless of which target this OUTER test binary itself is compiled
//! for. No `LYRIC_LOAD_COMPILER=1` recompile is needed.
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
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge
import Jvm.ZipReader

// Shared functional-interface binary name (`Jvm.Codegen.lambdaIfaceName`),
// duplicated here as a literal since the self-hosted `Jvm.Codegen` package
// isn't imported by this file (only `Jvm.Bridge` / `Jvm.ZipReader` are).
val sharedLambdaIfaceEntry: String = "Lyric/Lyric$Lambda.class"

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
    containsName(names, sharedLambdaIfaceEntry),
    sharedLambdaIfaceEntry + " must be present even though the package declares no lambda literal"
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
    if names[i] == sharedLambdaIfaceEntry {
      ifaceCount += 1
    }
    i += 1
  }
  assertEqualInt(ifaceCount, 1, "exactly one Lyric$Lambda interface entry, not zero or a duplicate")
}

test "a union case payload carrying a function type still emits the package's Lyric$Lambda interface (#6349)" {
  val dir = freshTempDir("union-payload")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.UnionPayload\n" + "\n" + "union Event {\n" + "  case OnClick(cb: (Int) -> Bool)\n" +
    "}\n" +
    "\n" +
    "pub func fire(e: in Event, x: Int): Bool {\n" +
    "  match e {\n" +
    "    case OnClick(cb) -> cb(x)\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val names = jarEntryNames(dir, "UnionPayload", source)
  assertTrue(
    containsName(names, sharedLambdaIfaceEntry),
    sharedLambdaIfaceEntry +
      " must be present when a union case payload field carries a function type, even with no lambda literal or function-typed func/record/interface signature elsewhere"
  )
}

test "an impl-block method's function-typed parameter still emits the package's Lyric$Lambda interface (#6350)" {
  val dir = freshTempDir("impl-callback")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.ImplCallback\n" + "\n" +
    "extern type JIntPredicate = \"java.util.function.IntPredicate\"\n" +
    "\n" +
    "record MyHandler { tag: Int }\n" +
    "\n" +
    "impl JIntPredicate for MyHandler {\n" +
    "  func test(self: in Self, value: Int, pred: (Int) -> Bool): Bool {\n" +
    "    pred(value)\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val names = jarEntryNames(dir, "ImplCallback", source)
  assertTrue(
    containsName(names, sharedLambdaIfaceEntry),
    sharedLambdaIfaceEntry +
      " must be present when an impl-block method's own parameter carries a function type — this is the ONLY signature source for a method implementing an external interface (no IInterface item exists in the file for that case)"
  )
}

test "a protected-type method's function-typed parameter still emits the package's Lyric$Lambda interface (#6350)" {
  val dir = freshTempDir("protected-callback")
  defer {
    cleanup(dir)
  }
  val source = "package Fixture.ProtectedCallback\n" + "\n" + "protected type Dispatcher {\n" + "  var tag: Int\n" +
    "\n" +
    "  func dispatch(pred: (Int) -> Bool): Bool {\n" +
    "    pred(tag)\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val names = jarEntryNames(dir, "ProtectedCallback", source)
  assertTrue(
    containsName(names, sharedLambdaIfaceEntry),
    sharedLambdaIfaceEntry +
      " must be present when a protected type's func member carries a function-typed parameter, even with no lambda literal or other function-typed signature elsewhere"
  )
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
    containsName(names, sharedLambdaIfaceEntry),
    "a package with no function-typed signature anywhere must not emit an unused interface class"
  )
}

// ─── Cross-package closure invocation (#5388/#5251) ─────────────────────────
// The full end-to-end proof: a closure literal written in one package,
// invoked through a function-typed parameter declared in ANOTHER package,
// via the real multi-package project bridge — then actually run under `java`.
// Before the fix this threw `ClassCastException: class LambdaCallerApp$
// Lambda$0 cannot be cast to class LambdaProviderPkg.Lyric$Lambda` at the
// `applyPred` call site; the shared `Lyric/Lyric$Lambda` interface (deduped
// by `Jvm.Bridge.codegenPackageInto`) makes the two packages' closures and
// call sites agree on one common interface type.
test "a lambda literal from one package invoked through another package's function-typed parameter runs correctly" {
  val dir = freshTempDir("xpkg-closure")
  defer {
    cleanup(dir)
  }
  val jarPath = Path.join(dir, "xpkg-closure.jar")
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package LambdaProviderPkg\n" + "\n" + "pub func applyPred(x: in Int, pred: in (Int) -> Bool): Bool {\n" +
      "  pred(x)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package LambdaCallerApp\n" + "\n" + "import LambdaProviderPkg\n" + "\n" + "func main(): Int {\n" +
      "  println(LambdaProviderPkg.applyPred(3, { y: Int -> y > 1 }))\n" +
      "  0\n" +
      "}\n"
  )
  val noStdlib: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPaths: List[String] = newList()
  var pi = 0
  while pi < pkgSrcs.count {
    noPaths.add("")
    pi += 1
  }
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    "LambdaCallerApp",
    noStdlib,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0",
    noPaths
  )
  assertTrue(ok, "cross-package closure fixture: compilation must succeed")
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  assertEqualInt(
    result.exitCode,
    0,
    "cross-package closure invocation must exit 0, not throw ClassCastException (stderr=" + result.stderr + ")"
  )
  assertEqual(Str.trim(result.stdout), "true", "cross-package closure invocation must run the real predicate")
}
