// jvm/self_test_b15.l — Stage B15: instance creation with new + invokespecial.
//
// Generates two class files:
//   Greeter.class — has <init>()V and greet()Ljava/lang/String;
//   Main.class    — main() creates a Greeter, calls greet(), prints result
//
// Exercises: new, dup, invokespecial (constructor + super), invokevirtual,
// areturn, and multi-method class serialization with a shared constant pool.
// Assembled into /tmp/lyric-jvm-b15/hello.jar; verified by JvmLoweringB15Test.

package Jvm.SelfTestB15

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeGreeterClassBytes(): List[Byte] {
  val pool = poolNew()

  // <init>()V: aload_0, invokespecial Object.<init>()V, return
  val asmInit  = newAssembler(pool)
  val objInit  = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // greet()Ljava/lang/String;: push string, areturn
  val asmGreet  = newAssembler(pool)
  emitPushString(asmGreet, "hello from b15")
  emitAreturn(asmGreet)
  val greetCode = assembleCode(asmGreet, 1, 1)
  val greetAttrs: List[Attribute] = newList()
  greetAttrs.add(greetCode)
  val greetMethod = makeMethodInfo(ACC_PUBLIC, "greet", "()Ljava/lang/String;", greetAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(greetMethod)
  val cf = makeClassWithMethods("Greeter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut       = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val greeterClass = poolClass(pool, "Greeter")
  val greeterInit  = poolMethodref(pool, "Greeter", "<init>", "()V")
  val greetMeth    = poolMethodref(pool, "Greeter", "greet", "()Ljava/lang/String;")
  val println_     = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOut)
  emitNew(asm, greeterClass)
  emitDup(asm)
  emitInvokespecial(asm, greeterInit)
  emitInvokevirtual(asm, greetMeth)
  emitInvokevirtual(asm, println_)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b15"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val greeterBytes = makeGreeterClassBytes()
  val mainBytes    = makeMainClassBytes()

  val greeterClass = BuiltClass(binaryName = "Greeter", bytes = greeterBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(greeterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB15",
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
