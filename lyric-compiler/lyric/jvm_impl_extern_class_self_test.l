//! jvm_impl_extern_class_self_test.l — regression tests for #5930: `impl
//! <ExternType> for Record` on `--target jvm` must reject a target that
//! resolves to a concrete or abstract JDK CLASS at compile time (an
//! `error[J006]` diagnostic), not silently emit an `implements <Class>`
//! clause. Before the fix, such a block compiled cleanly and produced
//! bytecode that threw `java.lang.IncompatibleClassChangeError` at
//! class-load time (only interfaces may appear in the JVM `interfaces`
//! table) — confirmed via `javap` on the emitted `.class` file and via a
//! real `java` run before this fix landed.
//!
//! `com.sun.net.httpserver.HttpsConfigurator` is the exact class from the
//! original report: `Std.HttpServer.startListenerTls` (docs/61 §6.3,
//! D-progress-692) needs to subclass it to enable mutual TLS, and this is
//! the compile-time guard that stands in for that unimplemented feature
//! (real concrete-class subclassing — `super_class` + `invokespecial` to a
//! chosen superclass constructor + override dispatch — is tracked
//! separately, not shipped here).
//!
//! Driven the same way `jvm_auto_ffi_bridge_self_test.l` drives its J005
//! (#2215) case: compiling is itself the observable behaviour under test,
//! so this calls `Jvm.Bridge.compileToJarBundled` in-process and asserts on
//! the `Bug` raised, rather than on a compiled program's runtime output.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so it can
//! import `Jvm.Bridge` without overflowing the F# bootstrap emitter's
//! transitive-closure limit, mirroring `jvm_auto_ffi_bridge_self_test.l`.
//! `lyric test` resolves these compiler-package imports from pre-compiled
//! stage-1 bundle DLLs, so no `LYRIC_LOAD_COMPILER=1` recompile is needed.
//! Run on the default (`dotnet`) target — the pipeline under test
//! (`Jvm.Bridge`) runs in-process regardless of which target the OUTER test
//! binary itself is compiled for.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/jvm_impl_extern_class_self_test.l
@test_module
package Lyric.JvmImplExternClassSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-impl-extern-class-" + label + "-" + uuidToString(newUuid()))
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

test "impl <abstract JDK class HttpsConfigurator> for Record aborts compilation under error[J006] (#5930)" {
  val dir = freshTempDir("https-configurator")
  val outPath = Path.join(dir, "HttpsConfiguratorImpl.jar")
  val source = "package HttpsConfiguratorImpl.App\n" + "\n" +
    "extern type JHttpsConfigurator = \"com.sun.net.httpserver.HttpsConfigurator\"\n" +
    "\n" +
    "extern type JHttpsParameters = \"com.sun.net.httpserver.HttpsParameters\"\n" +
    "\n" +
    "record MyConfigurator { tag: Int }\n" +
    "\n" +
    "impl JHttpsConfigurator for MyConfigurator {\n" +
    "  func configure(params: in JHttpsParameters): Unit { () }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "HttpsConfiguratorImpl", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(
    panicked,
    "`impl HttpsConfigurator for MyConfigurator` (abstract class) must abort compilation rather than compile successfully"
  )
  assertTrue(
    Str.contains(caughtMessage, "error[J006]"),
    "diagnostic carries the J006 code (got: " + caughtMessage + ")"
  )
  assertTrue(
    Str.contains(caughtMessage, "interface"),
    "diagnostic explains that only interfaces can be implemented (got: " + caughtMessage + ")"
  )
}

test "impl <concrete JDK class java.lang.Object> for Record also aborts under error[J006]" {
  val dir = freshTempDir("object-class")
  val outPath = Path.join(dir, "ObjectImpl.jar")
  val source = "package ObjectImpl.App\n" + "\n" + "extern type JObject = \"java.lang.Object\"\n" + "\n" +
    "record R { tag: Int }\n" +
    "\n" +
    "impl JObject for R {\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "ObjectImpl", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(panicked, "`impl java.lang.Object for R` (concrete class) must abort compilation")
  assertTrue(
    Str.contains(caughtMessage, "error[J006]"),
    "diagnostic carries the J006 code (got: " + caughtMessage + ")"
  )
}

test "impl <real JDK interface java.lang.Runnable> for Record still compiles fine (no J006 false-positive)" {
  val dir = freshTempDir("runnable-iface")
  val outPath = Path.join(dir, "RunnableImpl.jar")
  val source = "package RunnableImpl.App\n" + "\n" + "extern type JRunnable = \"java.lang.Runnable\"\n" + "\n" +
    "record R { tag: Int }\n" +
    "\n" +
    "impl JRunnable for R {\n" +
    "  func run(): Unit { () }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, "RunnableImpl", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  cleanup(dir)
  assertTrue(
    not panicked,
    "`impl Runnable for R` (real interface) must not raise J006 (message: " + caughtMessage + ")"
  )
  assertTrue(ok, "`impl Runnable for R` compiles successfully")
}
