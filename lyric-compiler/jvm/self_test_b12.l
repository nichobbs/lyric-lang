//! jvm/self_test_b12.l — Stage B12 smoke test: end-to-end JAR build + run.
//!
//! Generates Hello.class in memory, hands it to Jvm.Driver.writeJarFromClasses,
//! which assembles a JAR at /tmp/lyric-jvm-b12/hello.jar.
//!
//! The Expecto test (JvmLoweringB12Test.fs) then runs:
//!   java -jar /tmp/lyric-jvm-b12/hello.jar
//! and verifies the output contains "hello from b12".
//! This is the first test in the suite that executes a Lyric-generated JVM class.
package Jvm.SelfTestB12

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeHelloClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello from b12")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  emitInvokevirtual(asm, println_)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val mainAttrs: List[Attribute] = newList()
  mainAttrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", mainAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Hello", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b12"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val helloBytes = makeHelloClassBytes()

  val bc = BuiltClass(binaryName = "Hello", bytes = helloBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(bc)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB12",
    mainClass = "Hello",
    version = "0.1.0",
    outPath = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
