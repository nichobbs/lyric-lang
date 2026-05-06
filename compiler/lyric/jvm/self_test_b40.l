// jvm/self_test_b40.l — Stage B40: exception table (try/catch).
//
// Generates TryCatch.class with:
//   safeDivide(I,I)I — divides i0/i1; catches ArithmeticException → returns -1
//
// Method layout (Java 5 / major=49, no StackMapTable needed):
//   offset 0: iload_0   (1 byte)
//   offset 1: iload_1   (1 byte)
//   offset 2: idiv      (1 byte)
//   offset 3: ireturn   (1 byte)
//   offset 4: pop       (1 byte) ← exception handler
//   offset 5: iconst_m1 (1 byte)
//   offset 6: ireturn   (1 byte)
//
// Exception table: from=0, to=4, handler=4, catchType=ArithmeticException
//
// Main:
//   safeDivide(10, 2) → 5
//   safeDivide(10, 0) → -1   (ArithmeticException caught)
//
// Expected output:
//   5
//   -1

package Jvm.SelfTestB40

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeTryCatchClassBytes(): List[Byte] {
  val pool = poolNew()

  val arithmeticExIdx = poolClass(pool, "java/lang/ArithmeticException")

  // Build the safeDivide method body.
  val asmSD = newAssembler(pool)
  emitIload(asmSD, 0)        // offset 0: iload_0  (1 byte, Nullary)
  emitIload(asmSD, 1)        // offset 1: iload_1  (1 byte, Nullary)
  emitIdiv(asmSD)            // offset 2: idiv     (1 byte, Nullary)
  emitIreturn(asmSD)         // offset 3: ireturn  (1 byte, Nullary)
  // catch handler starts here at offset 4:
  emitPop(asmSD)             // offset 4: pop      (1 byte, Nullary)
  emitPushInt(asmSD, -1)    // offset 5: iconst_m1 (1 byte, Nullary via emitIconst)
  emitIreturn(asmSD)         // offset 6: ireturn  (1 byte, Nullary)

  val ar = assembleRaw(asmSD)

  val sdCode = makeCodeAttrWithHandler(
    2,                   // maxStack
    2,                   // maxLocals (slot0=param i, slot1=param j)
    ar.codeBytes,
    0,                   // startPc  = offset of try block start
    4,                   // endPc    = offset one past last try instruction
    4,                   // handlerPc = offset of catch handler
    arithmeticExIdx      // catchType = ArithmeticException class pool index
  )
  val sdAttrs: List[Attribute] = newList()
  sdAttrs.add(sdCode)
  val safeDivideMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "safeDivide",
    "(II)I",
    sdAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(safeDivideMethod)
  // Java 5 (major=49): no StackMapTable needed for exception handler targets
  val cf = makeClassWithMethodsV49("TryCatch", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val safeDivRef = poolMethodref(pool, "TryCatch", "safeDivide", "(II)I")
  val printlnI   = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // safeDivide(10, 2) → 5
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, safeDivRef)
  emitInvokevirtual(asm, printlnI)

  // safeDivide(10, 0) → -1
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
  val outDir = "/tmp/lyric-jvm-b40"
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
    packageName = "Jvm.SelfTestB40",
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
