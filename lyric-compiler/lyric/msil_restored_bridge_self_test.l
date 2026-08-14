//! msil_restored_bridge_self_test.l — end-to-end regression test for
//! restored-dependency (`[dependencies] path`) instance-method dispatch on
//! the self-hosted MSIL backend (#6440).  Completes the end-to-end
//! verification the #6439 review addendum (D-progress-757) found missing:
//! that PR's `methodRetIsSelf` marker fix for restored records could only
//! be verified at the registration level because dispatch itself never
//! reached the return-type check for a record-body method.
//!
//! Builds a real TWO-ASSEMBLY harness in-process, mirroring the CLI's
//! `[dependencies] path` restore exactly:
//!   1. A producer "lib" package compiles to its OWN standalone DLL via
//!      `Msil.Bridge.compileToMsil`.
//!   2. That DLL is reloaded through `Lyric.RestoredPackages.loadRestoredPackage`
//!      + `synthesiseArtifact` — the same contract-metadata round-trip the
//!      CLI's restore step performs.
//!   3. The resulting `SynthesisedArtifact` is threaded into a consumer
//!      package's compile via `Msil.Bridge.compileProjectToMsilWithRestored`.
//!   4. The consumer DLL is run via `dotnet exec` with the lib DLL copied
//!      beside it, so the runtime resolves the cross-assembly `AssemblyRef`
//!      exactly as a real two-project build would.
//!
//! Before #6440's fix, a plain method declared directly in a record's body
//! (as opposed to a separate `impl I for R {}` binding) was invisible to a
//! restored consumer at TWO levels: `Lyric.ContractMeta.reprForRecord`
//! dropped `RMFunc` members from the record's repr entirely, and
//! `Msil.Codegen.registerRestoredMembers`'s `IRecord` case never walked a
//! record's own methods (only `impl` blocks, via `registerRestoredImpl`).
//! Every call to such a method failed at runtime with "unsupported method
//! 'peek' on the receiver type", regardless of return type.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/msil_restored_bridge_self_test.l
@test_module
package Lyric.MsilRestoredBridgeSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Msil.Bridge
import Lyric.RestoredPackages
import Lyric.ContractMeta as Meta

// ─── Helpers ────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-msil-restored-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) } else { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func copyFile(src: in String, dest: in String): Unit {
  match File.readBytes(src) {
    case Ok(bs) -> {
      val _ = File.writeBytes(dest, bs)
    }
    case Err(_) -> ()
  }
}

// Compile `source` (a single package) to a standalone producer DLL named
// `<dllName>.dll`, then reload it through the exact
// `Lyric.RestoredPackages` round-trip the CLI's `[dependencies] path`
// restore uses.  Returns the resulting `SynthesisedArtifact`; the caller is
// responsible for cleaning up `art.dllPath`'s directory once it has copied
// the DLL beside the consumer's output.
func buildRestoredArtifact(label: in String, source: in String, dllName: in String): SynthesisedArtifact {
  val libDir = freshTempDir(label + "-lib")
  val libDllPath = Path.join(libDir, dllName + ".dll")
  val noStdlib: List[String] = newList()
  val ok = compileToMsil(source, libDllPath, noStdlib)
  if not ok {
    cleanup(libDir)
    panic(label + ": compileToMsil (producer) returned false")
  }
  match loadRestoredPackage(libDllPath) {
    case Err(e) -> {
      cleanup(libDir)
      panic(label + ": loadRestoredPackage failed: " + errorMessage(e))
    }
    case Ok(artifacts) -> {
      if artifacts.count != 1 {
        cleanup(libDir)
        panic(label + ": expected exactly 1 restored artifact, got " + artifacts.count.toString())
      }
      val noPreamble: List[Meta.ContractDecl] = newList()
      match synthesiseArtifact(artifacts[0], noPreamble) {
        case Err(e) -> {
          cleanup(libDir)
          panic(label + ": synthesiseArtifact failed: " + errorMessage(e))
        }
        case Ok(art) -> art
      }
    }
  }
}

// Compile `consumerSource` against `restoredArt` as a restored dependency,
// copy the producer DLL beside the consumer output, run it, and return the
// captured result.  Cleans up both temp directories before returning.
func compileAndRunAgainstRestored(
  label: in String,
  consumerSource: in String,
  consumerName: in String,
  restoredArt: in SynthesisedArtifact,
): Capture.CaptureResult {
  val appDir = freshTempDir(label + "-app")
  val appDllPath = Path.join(appDir, consumerName + ".dll")
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(ProjectPackagePayload(name = consumerName, source = consumerSource))
  val noStdlib: List[String] = newList()
  val noFeatures: List[String] = newList()
  val artifacts: List[SynthesisedArtifact] = newList()
  artifacts.add(restoredArt)
  val ok = compileProjectToMsilWithRestored(
    packages,
    consumerName,
    appDllPath,
    noStdlib,
    noFeatures,
    noFeatures,
    artifacts
  )
  val libDir = Path.dirname(restoredArt.dllPath)
  if not ok {
    cleanup(appDir)
    cleanup(libDir)
    panic(label + ": compileProjectToMsilWithRestored (consumer) returned false")
  }
  copyFile(restoredArt.dllPath, Path.join(appDir, Path.basename(restoredArt.dllPath)))
  writeRuntimeConfig(appDllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(appDllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(appDir)
  cleanup(libDir)
  result
}

// ─── Shared fixture source ────────────────────────────────────────────────
// `Decoy` shares the `base` field name with `Counter` — pins the same
// field-token collision guard #6434/#6439 verified for the same-assembly
// path, now for a restored record.
val libSource: String = "package RestoredMethodLib\n" + "\n" + "pub record Decoy {\n" + "  base: Int\n" + "}\n" + "\n" + "pub record Counter {\n" + "  base: Int\n" + "\n" + "  func peek(self: in Counter): Int {\n" + "    self.base + 2\n" + "  }\n" + "\n" + "  func bump(self: in Counter): Self {\n" + "    Counter(base = self.base + 1)\n" + "  }\n" + "}\n"

// `Box[T]` — a generic record with two inherent (record-body) methods: one
// whose RETURN mentions `T` (`get`), one whose PARAM mentions `T` (`set`).
// Pins #6442: `registerRestoredRecordBodyMethods`/`registerRestoredRecordMethod`
// did not thread the record's own generic-parameter names through
// `typeExprToMsilCtx`'s generics-aware VAR-form path the way
// `registerRestoredRecordCtor`/`registerRestoredRecordFields` already do.
val genericLibSource: String = "package RestoredGenericLib\n" + "\n" + "pub record Box[T] {\n" + "  value: T\n" + "\n" + "  func get(self: in Box[T]): T {\n" + "    self.value\n" + "  }\n" + "\n" + "  func set(self: in Box[T], v: T): T {\n" + "    v\n" + "  }\n" + "}\n"

// ─── Tests ─────────────────────────────────────────────────────────────────
// A plain (non-`Self`-returning) record-body method on a restored record
// dispatches correctly.  Before #6440 this failed at runtime with
// "unsupported method 'peek' on the receiver type" — no dispatch key was
// ever registered, since only `impl I for R {}` bindings registered the
// concrete-record method key (`registerRestoredImpl`), and a plain
// record-body method has no such binding.
test "restored record-body method (plain return type) dispatches correctly" {
  val art = buildRestoredArtifact("plain", libSource, "RestoredMethodLib")
  val consumerSrc = "package RestoredMethodApp\n" + "\n" + "import RestoredMethodLib\n" + "\n" + "func main(): Unit {\n" +
    "  val c = Counter(base = 40)\n" +
    "  println(c.peek())\n" +
    "}\n"
  val result = compileAndRunAgainstRestored("plain", consumerSrc, "RestoredMethodApp", art)
  assertEqualInt(result.exitCode, 0, "restored_plain_method: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "restored_plain_method: stdout matches expected")
}

// A `Self`-returning restored record-body method, CHAINED
// (`c.bump().bump()`), dispatches correctly against the narrowed receiver
// type at both call sites — the #6435/#6439 scenario, now exercised through
// a real two-assembly restored build for the first time.  Also exercises
// the field-token collision guard (#6434) via the shared `base` field name
// on `Decoy`.
test "restored record-body method (Self return, chained) dispatches correctly with a field-name collision present" {
  val art = buildRestoredArtifact("chained", libSource, "RestoredMethodLib")
  val consumerSrc = "package RestoredMethodChainApp\n" + "\n" + "import RestoredMethodLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val c = Counter(base = 40)\n" +
    "  val chained = c.bump().bump()\n" +
    "  println(chained.base)\n" +
    "  println(chained.peek())\n" +
    "}\n"
  val result = compileAndRunAgainstRestored("chained", consumerSrc, "RestoredMethodChainApp", art)
  assertEqualInt(result.exitCode, 0, "restored_chained_self_method: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42\n44", "restored_chained_self_method: stdout matches expected")
}

// A restored generic record's inherent methods dispatch correctly for a
// VALUE-TYPE instantiation (`Box[Int]`) — both the T-returning method
// (`get`) and the T-parameter method (`set`) (#6442).
test "restored generic record-body methods dispatch correctly for a value-type instantiation" {
  val art = buildRestoredArtifact("genint", genericLibSource, "RestoredGenericLib")
  val consumerSrc = "package RestoredGenericAppInt\n" + "\n" + "import RestoredGenericLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val b = Box(value = 42)\n" +
    "  println(b.get())\n" +
    "  println(b.set(99))\n" +
    "}\n"
  val result = compileAndRunAgainstRestored("genint", consumerSrc, "RestoredGenericAppInt", art)
  assertEqualInt(result.exitCode, 0, "restored_generic_value_type: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42\n99", "restored_generic_value_type: stdout matches expected")
}

// A restored generic record's inherent methods dispatch correctly for a
// REFERENCE-TYPE instantiation (`Box[String]`) — same two methods (#6442).
test "restored generic record-body methods dispatch correctly for a reference-type instantiation" {
  val art = buildRestoredArtifact("genstr", genericLibSource, "RestoredGenericLib")
  val consumerSrc = "package RestoredGenericAppStr\n" + "\n" + "import RestoredGenericLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val b = Box(value = \"hello\")\n" +
    "  println(b.get())\n" +
    "  println(b.set(\"world\"))\n" +
    "}\n"
  val result = compileAndRunAgainstRestored("genstr", consumerSrc, "RestoredGenericAppStr", art)
  assertEqualInt(result.exitCode, 0, "restored_generic_reference_type: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "hello\nworld", "restored_generic_reference_type: stdout matches expected")
}
