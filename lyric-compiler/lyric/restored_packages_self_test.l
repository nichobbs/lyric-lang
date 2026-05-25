// restored_packages_self_test.l — exercises the `Lyric.RestoredPackages`
// loader (#1229 Phase A.3.2).  Compiled and executed by
// SelfHostedRestoredPackagesTests.fs.  Exit 0 + "ok" in stdout means
// every assertion held.

package Lyric.RestoredPackages.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.RestoredPackages

func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "self_hosted_restored_packages.dll")
}

// Happy path: the running test PE has an embedded `Lyric.Contract`
// (every Lyric-emitted assembly does), so the loader returns one
// artifact with a populated package name.
func testLoadRunningPe(): Unit {
  match loadRestoredPackage(selfDllPath()) {
    case Err(e) -> panic("load_running_pe: " + errorMessage(e))
    case Ok(artifacts) -> {
      assertTrue(artifacts.count >= 1,
        "load_running_pe: at least one artifact")
      val a = artifacts[0]
      assertTrue(Str.isNotEmpty(a.packageName),
        "load_running_pe: packageName non-empty")
      assertEqual(a.dllPath, selfDllPath(),
        "load_running_pe: dllPath round-trips")
      // contract.packageName is the source of truth for legacy-form
      // resources — confirm it lines up with the artifact's name.
      assertEqual(a.contract.packageName, a.packageName,
        "load_running_pe: artifact.packageName matches contract.packageName")
    }
  }
}

// Missing path → DllMissing error.
func testMissingFileError(): Unit {
  match loadRestoredPackage("/definitely/does/not/exist.dll") {
    case Ok(_) -> panic("missing_file: expected Err")
    case Err(e) -> {
      match e {
        case DllMissing(p) ->
          assertEqual(p, "/definitely/does/not/exist.dll",
            "missing_file: path round-trips")
        case _ -> panic("missing_file: expected DllMissing, got: " + errorMessage(e))
      }
    }
  }
}

// errorMessage produces a non-empty string for each variant — pinning
// the diagnostic surface.
func testErrorMessageVariants(): Unit {
  val m1 = errorMessage(DllMissing(path = "/x.dll"))
  assertTrue(Str.contains(m1, "/x.dll"),
    "error_message: DllMissing mentions path")
  val m2 = errorMessage(NoContractResource(path = "/y.dll"))
  assertTrue(Str.contains(m2, "/y.dll"),
    "error_message: NoContractResource mentions path")
  val m3 = errorMessage(MalformedContract(path = "/z.dll", pkgKey = "Foo"))
  assertTrue(Str.contains(m3, "/z.dll"),
    "error_message: MalformedContract mentions path")
  assertTrue(Str.contains(m3, "Foo"),
    "error_message: MalformedContract mentions pkgKey")
}

func main(): Int {
  testLoadRunningPe()
  testMissingFileError()
  testErrorMessageVariants()
  println("restored-packages self-test: ok")
  return 0
}
