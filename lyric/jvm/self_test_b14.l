// jvm/self_test_b14.l — Stage B14 smoke test: multi-class JAR with invokestatic.
//
// Generates two class files:
//   Helper.class  — static greet() returning "hello from b14"
//   Main.class    — main() calls Helper.greet() via invokestatic, prints result
//
// Both are assembled into /tmp/lyric-jvm-b14/hello.jar.
// JvmLoweringB14Test.fs runs `java -jar` and verifies the output.
// This is the first test exercising cross-class invokestatic in Lyric-emitted bytecode.

package Jvm.SelfTestB14

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeHelperClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // greet() returns the String "hello from b14" via areturn.
  emitPushString(asm, "hello from b14")
  emitAreturn(asm)

  val codeAttr = assembleCode(asm, 1, 0)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val greetMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "greet", "()Ljava/lang/String;", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(greetMethod)
  val cf = makeClassWithMethods("Helper", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // main(): getstatic System.out, invokestatic Helper.greet(), invokevirtual println, return.
  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val greet_   = poolMethodref(pool, "Helper", "greet", "()Ljava/lang/String;")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, greet_)
  emitInvokevirtual(asm, println_)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b14"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val helperBytes = makeHelperClassBytes()
  val mainBytes   = makeMainClassBytes()

  val helperClass = BuiltClass(binaryName = "Helper", bytes = helperBytes)
  val mainClass   = BuiltClass(binaryName = "Main",   bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(helperClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB14",
    mainClass   = "Main",
    version     = "0.1.0",
    outPath     = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
