// jvm/self_test_b7.l — Stage B7 smoke test: native-image config file generation.
//
// Calls each Jvm.NativeImage function and writes the resulting JSON strings
// to /tmp/lyric-jvm-b7/ so the Expecto test (JvmLoweringB7Test.fs) can
// verify the contents without needing GraalVM installed.

package Jvm.SelfTestB7

import Std.Core
import Std.File
import Jvm.NativeImage

func main(): Unit {
  val pkgName = "TestPkg"
  val outDir = "/tmp/lyric-jvm-b7"
  val _ = createDir(outDir)
  match writeText(outDir + "/reflect-config.json", reflectConfigJson()) {
    case Ok(_)  -> println("wrote reflect-config.json")
    case Err(_) -> println("writeText failed: reflect-config.json")
  }
  match writeText(outDir + "/resource-config.json", resourceConfigJson(pkgName)) {
    case Ok(_)  -> println("wrote resource-config.json")
    case Err(_) -> println("writeText failed: resource-config.json")
  }
  match writeText(outDir + "/proxy-config.json", proxyConfigJson()) {
    case Ok(_)  -> println("wrote proxy-config.json")
    case Err(_) -> println("writeText failed: proxy-config.json")
  }
  match writeText(outDir + "/jni-config.json", jniConfigJson()) {
    case Ok(_)  -> println("wrote jni-config.json")
    case Err(_) -> println("writeText failed: jni-config.json")
  }
}
