//! jvm_auto_ffi_bridge_self_test.l — regression tests for two JVM auto-FFI
//! robustness gaps from `docs/44-jvm-production-readiness-plan.md` (m-7,
//! M-15) that require driving the in-process `Jvm.Bridge` / `Jvm.AutoFfi`
//! pipeline directly rather than compiling ordinary user code (the pattern
//! `auto_ffi_jvm_self_test.l` uses):
//!
//!   * m-7 (#2214): `Jvm.AutoFfi.splitPathListOn` must split `LYRIC_FFI_JARS`
//!     on the platform-correct separator ONLY (`;` on Windows, `:`
//!     elsewhere), never both — splitting on both misparses a Windows
//!     absolute path's drive-letter colon (`C:\foo.jar`).  `splitPathListOn`
//!     takes the "is this host Windows" flag as an explicit parameter (the
//!     same testability pattern `AppHost.launcherName` /
//!     `AppHost.preferHostRid` use for their RID parameter) so the Windows
//!     behaviour is asserted deterministically regardless of the actual CI
//!     host running this suite.
//!   * M-15 part 1 (#2215): `T.new()` on an `extern type` naming an abstract
//!     JDK class must abort compilation with an `error[J005]` diagnostic
//!     instead of producing bytecode that throws `InstantiationError` at
//!     runtime.  Compiling is itself the observable behaviour under test, so
//!     this drives `Jvm.Bridge.compileToJarBundled` in-process and asserts on
//!     the `Bug` raised, rather than asserting on a compiled program's
//!     runtime output.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so it can
//! import `Jvm.AutoFfi` / `Jvm.Bridge` without overflowing the F# bootstrap
//! emitter's transitive-closure limit, mirroring
//! `msil_project_bridge_self_test.l`.  `lyric test` resolves these
//! compiler-package imports from pre-compiled stage-1 bundle DLLs, so no
//! `LYRIC_LOAD_COMPILER=1` recompile is needed.  Run on the default
//! (`dotnet`) target — the pipeline under test runs in-process regardless of
//! which target the OUTER test binary itself is compiled for; M-15 part 2
//! (`findBestInstanceMethod` walking to `java/lang/Object`) is covered
//! end-to-end on the real JVM target by `auto_ffi_jvm_self_test.l` instead,
//! since it needs an actual JVM run to prove the resolved call executes
//! correctly.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/jvm_auto_ffi_bridge_self_test.l
@test_module
package Lyric.JvmAutoFfiBridgeSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.AutoFfi
import Jvm.Bridge
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

// ─── m-7 / #2214: splitPathListOn separator handling ─────────────────────────
test "splitPathListOn splits on ':' only when the host is not Windows" {
  val parts = splitPathListOn("/opt/libs/a.jar:/opt/libs/b.jar", false)
  assertEqualInt(parts.count, 2, "two paths split on ':'")
  assertEqual(parts[0], "/opt/libs/a.jar", "first path")
  assertEqual(parts[1], "/opt/libs/b.jar", "second path")
}

test "splitPathListOn preserves Windows drive-letter colons and splits on ';' (#2214)" {
  val parts = splitPathListOn("C:\\libs\\a.jar;C:\\libs\\b.jar", true)
  assertEqualInt(parts.count, 2, "two paths split on ';', drive-letter colons untouched")
  assertEqual(parts[0], "C:\\libs\\a.jar", "first path keeps its drive-letter colon intact")
  assertEqual(parts[1], "C:\\libs\\b.jar", "second path keeps its drive-letter colon intact")
}

test "splitPathListOn on Windows does not split a single drive-letter path into bogus fragments (#2214)" {
  val parts = splitPathListOn("C:\\libs\\a.jar", true)
  assertEqualInt(parts.count, 1, "single path survives unsplit — the pre-fix bug split this into 2")
  assertEqual(parts[0], "C:\\libs\\a.jar", "unsplit, drive-letter colon intact")
}

test "splitPathListOn treats ';' as ordinary text when the host is not Windows" {
  // Guards the "single separator only" property in the other direction: a
  // stray ';' in a non-Windows path list must not be treated as a delimiter.
  val parts = splitPathListOn("/opt/libs/a;b.jar:/opt/libs/c.jar", false)
  assertEqualInt(parts.count, 2, "only ':' delimits on a non-Windows host")
  assertEqual(parts[0], "/opt/libs/a;b.jar", "';' inside the first path is not a separator")
  assertEqual(parts[1], "/opt/libs/c.jar", "second path")
}

// ─── M-15 part 1 / #2215: T.new() on an abstract JDK class ──────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-autoffi-bridge-" + label + "-" + uuidToString(newUuid()))
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

test "T.new() on an abstract JDK class aborts compilation under error[J005], not a runtime InstantiationError (#2215)" {
  val dir = freshTempDir("abstract-ctor")
  val outPath = Path.join(dir, "AbstractCtor.jar")
  val source = "package AbstractCtor.App\n" + "\n" + "extern type JReader = \"java.io.Reader\"\n" + "\n" +
    "func main(): Unit {\n" +
    "  val r = JReader.new()\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "AbstractCtor", noStdlib, "")
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(
    panicked,
    "constructing java.io.Reader (abstract) must abort compilation rather than compiling successfully"
  )
  assertTrue(
    Str.contains(caughtMessage, "error[J005]"),
    "diagnostic carries the J005 code (got: " + caughtMessage + ")"
  )
  assertTrue(
    Str.contains(caughtMessage, "abstract"),
    "diagnostic names the abstract-class problem (got: " + caughtMessage + ")"
  )
}

test "T.new() on a concrete JDK class still compiles fine (no false-positive J005)" {
  val dir = freshTempDir("concrete-ctor")
  val outPath = Path.join(dir, "ConcreteCtor.jar")
  val source = "package ConcreteCtor.App\n" + "\n" + "extern type JStringBuilder = \"java.lang.StringBuilder\"\n" + "\n" +
    "func main(): Unit {\n" +
    "  val sb = JStringBuilder.new()\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, "ConcreteCtor", noStdlib, "")
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  cleanup(dir)
  assertTrue(not panicked, "StringBuilder (concrete) must not raise J005 (message: " + caughtMessage + ")")
  assertTrue(ok, "StringBuilder (concrete) construction compiles successfully")
}

// ─── #6565: java.lang.Object-inherited method fallback when the receiver's
// class metadata cannot be loaded (Maven-sourced extern type, no JAR on the
// auto-FFI classpath — the exact `lyric-web` `Web.Kernel.Runtime` shape,
// where `extern type JHttpString = "io.undertow.util.HttpString"` has no
// `lyric-resolver.jar`-resolved Undertow JAR available at compile time) ────
//
// When `Jvm.Codegen.lowerMethodCall` cannot load ANY metadata for the
// receiver's class (a made-up FQN below plays the role of an
// unresolved-Maven-JAR class — the auto-FFI resolver behaves identically
// either way: `loadClass` returns `None`), it used to fall back to
// `()Object` for EVERY method, including `toString()`/`hashCode()`/
// `equals(Object)` — the three methods every reference type inherits from
// `java.lang.Object` with a signature the JVM spec fixes regardless of the
// receiver's real (unresolvable) class.  A chained Lyric stdlib `String`
// extension call (`.toLower()`) off that untyped `.toString()` result then
// failed auto-FFI resolution against `java.lang.Object` instead of
// `String`.  The receiver value here is only ever a function PARAMETER
// (never constructed) — `T.new()` on an unresolvable-metadata class hits
// the UNRELATED "class not found" hard-panic path this same file's
// abstract-ctor tests exercise above, so exercising the instance-call
// fallback needs a value whose static type is the extern type without a
// construction call ever executing.
test "toString()/hashCode()/equals() on an extern type with no resolvable class metadata still compile with their real signature, not ()Object (#6565)" {
  val dir = freshTempDir("no-metadata-object-methods")
  val outPath = Path.join(dir, "NoMetadataObjectMethods.jar")
  val source = "package NoMetadataObjectMethods.App\n" + "\n" +
    "extern type JUnresolvable = \"com.example.nonexistent.NotARealJdkOrMavenClass\"\n" +
    "\n" +
    "func describe(x: in JUnresolvable): String {\n" +
    "  x.toString().toLower()\n" +
    "}\n" +
    "\n" +
    "func codeOf(x: in JUnresolvable): Int {\n" +
    "  x.hashCode()\n" +
    "}\n" +
    "\n" +
    "func sameAs(x: in JUnresolvable, y: in JUnresolvable): Bool {\n" +
    "  x.equals(y)\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, "NoMetadataObjectMethods", noStdlib, "")
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  cleanup(dir)
  assertTrue(
    not panicked,
    "toString()/hashCode()/equals() on a metadata-unresolvable extern type must not panic (message: " + caughtMessage +
      ")"
  )
  assertTrue(ok, "toString().toLower() / hashCode() / equals() all compile against a metadata-unresolvable receiver")
}

test "a genuinely unknown method on a metadata-unresolvable extern type still degrades to Object, not a pinned type (control for #6565)" {
  // Guards against the #6565 fix silently widening into "every method on an
  // unresolvable receiver gets a precise type" — only the three real
  // `java.lang.Object` methods (`toString`/`hashCode`/`equals`) are pinned.
  // Any OTHER first-hop method name still falls back to the untyped `Object`
  // guess exactly as before the fix; chaining a call that Object itself does
  // not declare onto that untyped result must still surface the existing
  // "no matching instance or inherited method" diagnostic — proving the
  // fallback for a non-pinned method name was NOT widened.
  val dir = freshTempDir("no-metadata-unknown-method")
  val outPath = Path.join(dir, "NoMetadataUnknownMethod.jar")
  val source = "package NoMetadataUnknownMethod.App\n" + "\n" +
    "extern type JUnresolvable = \"com.example.nonexistent.NotARealJdkOrMavenClass\"\n" +
    "\n" +
    "func totallyMadeUp(x: in JUnresolvable): String {\n" +
    "  x.thisMethodDoesNotExistAnywhere().toLower()\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "NoMetadataUnknownMethod", noStdlib, "")
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(
    panicked,
    "a non-pinned method's Object-typed fallback result must still fail a chained .toLower() call, not silently type as String"
  )
  assertTrue(
    Str.contains(caughtMessage, "no matching instance or inherited method"),
    "diagnostic still names the unresolved-method problem (got: " + caughtMessage + ")"
  )
}

// ─── #6565 end-to-end: the reported acceptance criterion ────────────────────
//
// `lyric build --manifest lyric-web/lyric.toml --target jvm` failed to build
// the real `Web.Kernel.Runtime` package: `buildRequestHeaders`'s
// `name.toString().toLower()` (`name` an `io.undertow.util.HttpString`,
// resolved via the `JHttpStringCollection[T]` phantom-generic-collection
// idiom) failed with "no matching instance or inherited method for
// 'java.lang.Object.toLower()'" — `name`'s static type had erased to
// `Object` (the type-checker half of this fix) and, in whatever compile-time
// environment #6565 was originally observed in, `.toString()`'s return type
// ALSO fell back to the untyped `()Object` guess (the codegen half of this
// fix) instead of resolving via real JDK metadata.
//
// Drives the exact CLI entry point (`Lyric.Cli.buildProject`, what
// `lyric build --manifest ... --target jvm` itself calls) against the real
// on-disk `lyric-web/lyric.toml`, run from the repo root (`lyric test`'s own
// working directory) — this is the literal repro command from the issue.
//
// IMPORTANT — this is an environment-dependent SMOKE test, not a hermetic
// regression guard for #6565's exact failure mode: it requires a restored
// Maven classpath for `io.undertow:undertow-core` (`lyric restore --manifest
// lyric-web/lyric.toml` with `LYRIC_MAVEN_RESOLVER` set, network access to
// Maven Central) to get past `JHttpString.new(...)`'s own static-constructor
// auto-FFI resolution elsewhere in the same package — without that restored
// classpath, this test fails on an unrelated, already-correct diagnostic
// ("class 'io.undertow.util.HttpString' not found in JDK jmods or
// LYRIC_FFI_JARS", M-15 part 1, docs/44) rather than #6565's error, on any
// host where JDK jmods are discoverable (`Jvm.AutoFfi.findJmodsDir`) — which
// is effectively every real dev machine and CI runner with `java` installed.
// And once a real, restored Undertow classpath IS available, #6565's exact
// symptom is actually LATENT here regardless of either fix: `name.toString()`
// resolves via real `java.lang.Object` metadata (always resolvable — Object
// is a core JDK class) whether or not `name`'s static type is correctly
// `JHttpString`, and `Object.toString()`'s real signature already returns
// `String`, so `.toLower()` succeeds either way. This test therefore mainly
// re-proves the acceptance criterion from #6565's own report (`lyric build
// --manifest lyric-web/lyric.toml --target jvm` must succeed) rather than
// discriminating the fix. The two tests directly above (real, deliberately
// metadata-unresolvable extern methods) and
// `auto_ffi_jvm_self_test.l`'s "for-loop over an extern generic collection"
// test (real runtime values through the actual erased-vs-typed element
// path) are the hermetic regression guards for #6565's two root causes —
// see their own comments for why each is deterministic regardless of the
// host's JDK/Maven configuration.
test "Cli.buildProject: lyric-web --manifest --target jvm succeeds end-to-end (acceptance criterion for #6565, requires a restored Maven classpath — see comment above)" {
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    "lyric-web/lyric.toml",
    None,
    Emitter.Jvm,
    noFeatures,
    false,
    false,
    false,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(
    rc,
    0,
    "lyric build --manifest lyric-web/lyric.toml --target jvm must succeed — previously failed with " +
      "'JVM auto-FFI: no matching instance or inherited method for java.lang.Object.toLower()' compiling " +
      "Web.Kernel.Runtime.buildRequestHeaders (#6565)"
  )
}
