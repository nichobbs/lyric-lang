//! qualified_static_val_capture_self_test.l — regression test for
//! `tryQualifiedStaticValNameMsil`'s local-vs-qualified-static-val guard
//! missing closure-captured locals (#5274).
//!
//! `tryQualifiedStaticValNameMsil` (lyric-compiler/msil/codegen.l) resolves
//! a dotted `EMember` chain like `Lib.NAME` to a cross-package qualified
//! `pub val` read, but must first check whether the chain's first segment
//! actually names a LOCAL (`ShadowVal.Lib.secret` field access through a
//! local named `ShadowVal`, not the package `ShadowVal.Lib`'s static val
//! `secret`) — see msil_project_bridge_self_test.l's #5265 regression.
//!
//! That guard originally checked only `fctx.slots` (the per-lambda/per-func
//! fresh local table). A variable CAPTURED by a closure is instead recorded
//! in `fctx.captureNameToIndex` / `fctx.hoistedCellSlot` — maps a lambda
//! body's `fctx` never populates into `slots`. So a local captured by a
//! closure, whose name collides with an imported package's first segment,
//! was misdetected as "not a local" inside the closure body and silently
//! flattened to the package's qualified static-val key instead of reading
//! the captured local's own field.
//!
//! This test builds two packages: `Cap5274.Lib` (declares a `pub val NAME`)
//! and `Cap5274.App` (declares a local named `Lib` — colliding with the
//! imported package's own name — with a field also named `NAME`, captured
//! by a closure that reads `Lib.NAME`). Before the fix the closure prints
//! the package's static val ("pkg-value"); after the fix it prints the
//! captured local's field ("captured-value").
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/qualified_static_val_capture_self_test.l
@test_module
package Lyric.QualifiedStaticValCaptureSelfTest

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

// ─── Minimal cross-package compile+run harness (mirrors
// msil_project_bridge_self_test.l's private helpers; duplicated here rather
// than shared since those helpers are not `pub`) ─────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-qsv-cap-" + label + "-" + uuidToString(newUuid()))
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

func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

func compileAndRun(
  label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()
  val ok = compileProjectToMsil(packages, assemblyName, dllPath, stdlibSources)
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToMsil returned false")
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  result
}

// ─── Regression: closure-captured local shadowing a package name is not
// mistaken for a qualified static val (#5274) ────────────────────────────────
test "closure-captured local shadowing a package name reads its own field, not the qualified static val" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("Cap5274.Lib", "package Cap5274.Lib\n" + "\n" + "pub val NAME: String = \"pkg-value\"\n"))
  packages.add(
    mkPkg(
      "Cap5274.App",
      "package Cap5274.App\n" + "\n" + "import Cap5274.Lib\n" + "\n" + "record Box { NAME: String }\n" + "\n" +
        "func main(): Unit {\n" +
        "  val Lib = Box(NAME = \"captured-value\")\n" +
        "  val getter = || Lib.NAME\n" +
        "  println(getter())\n" +
        "}\n"
    )
  )
  val result = compileAndRun("qsvcap", packages, "Cap5274")
  assertEqualInt(result.exitCode, 0, "closure_captured_shadow: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "captured-value",
    "closure_captured_shadow: captured local field wins over qualified static val"
  )
}
