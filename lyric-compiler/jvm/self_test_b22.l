// jvm/self_test_b22.l — Stage B22: exception handling with try/catch.
//
// Generates TryCatch.class with safeDiv(I,I)I that catches ArithmeticException
// from integer division by zero and returns -1.  Main calls safeDiv(10,2)=5
// and safeDiv(10,0)=-1.
//
// Uses assembleRaw + makeCodeAttrWithHandler to set the exception table.
// Targets Java 5 (major=49) to avoid the StackMapTable requirement at the
// exception handler entry point (which has the exception object on the stack,
// requiring a same_locals_1_stack_item frame — tracked as B23+).

package Jvm.SelfTestB22

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeTryCatchClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // safeDiv(I,I)I layout (all 1-byte instructions):
  //   offset 0: iload_0
  //   offset 1: iload_1
  //   offset 2: idiv         (throws ArithmeticException on div-by-zero)
  //   offset 3: ireturn
  //   offset 4: pop           (handler entry: discard ArithmeticException)
  //   offset 5: iconst_m1    (-1)
  //   offset 6: ireturn
  emitIload(asm, 0)
  emitIload(asm, 1)
  emitIdiv(asm)
  emitIreturn(asm)
  emitPop(asm)
  emitPushInt(asm, -1)
  emitIreturn(asm)

  val ar      = assembleRaw(asm)
  val exClass = poolClass(pool, "java/lang/ArithmeticException")

  // Exception table: try [0, 4) → handler 4, catch ArithmeticException
  val codeAttr = makeCodeAttrWithHandler(2, 2, ar.codeBytes, 0, 4, 4, exClass)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val divMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "safeDiv", "(II)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(divMethod)

  val cf = makeClassWithMethodsV49("TryCatch", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val safeDivRef = poolMethodref(pool, "TryCatch", "safeDiv", "(II)I")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // println(safeDiv(10, 2))  → 5
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, safeDivRef)
  emitInvokevirtual(asm, printlnI)

  // println(safeDiv(10, 0))  → -1
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, safeDivRef)
  emitInvokevirtual(asm, printlnI)

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
  val outDir = "/tmp/lyric-jvm-b22"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val tryCatchBytes = makeTryCatchClassBytes()
  val mainBytes     = makeMainClassBytes()

  val tryCatchClass = BuiltClass(binaryName = "TryCatch", bytes = tryCatchBytes)
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(tryCatchClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB22",
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
