// jvm/self_test_b100.l — Stage B100: exception handling (LTryCatch in lowerFunc).
//
// Adds LTryCatch meta-insn support to lowerFunc: the insn declares an exception
// table entry (startLabel, endLabel, handlerLabel, catchClass) without emitting
// bytecode; lowerFunc collects these and writes the exception_table in the Code
// attribute.  Handler labels are also added as StackMapTable targets (with the
// caught exception type on the stack).
//
// Creates a SafeMath class with safeDivide(int a, int b): int that returns:
//   - a/b normally
//   - -1 if b==0 (catches ArithmeticException)
//
// Java output (java -jar):
//   divide(10,2)=5
//   divide(10,0)=-1

package Jvm.SelfTestB100

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeSafeDivideMethod(): LFunc {
  // safeDivide(int a, int b): int
  //   slot 0 = a
  //   slot 1 = b
  //   slot 2 = result (stored before branch target)
  //
  // Pattern:
  //   result = -1                   (default — ArithmeticException case)
  //   LTryCatch("try_start", "try_end", "catch_ae", "java/lang/ArithmeticException")
  //   [try_start]:
  //   result = a / b
  //   [try_end]:
  //   goto done
  //   [catch_ae]:                   // handler: exception ref on stack, store it -> discard
  //   astore slot 3                 // pop exception
  //   (result already -1)
  //   [done]:
  //   return result
  val insns: List[LInsn] = newList()
  insns.add(LIconst(v = -1))
  insns.add(LIstore(slot = 2))         // result = -1

  insns.add(LTryCatch(
    startLabel   = "try_start",
    endLabel     = "try_end",
    handlerLabel = "catch_ae",
    catchClass   = "java/lang/ArithmeticException"
  ))

  insns.add(LLabel(name = "try_start"))
  insns.add(LIload(slot = 0))          // a
  insns.add(LIload(slot = 1))          // b
  insns.add(LIdiv)                     // a / b (throws ArithmeticException if b==0)
  insns.add(LIstore(slot = 2))         // result = a/b
  insns.add(LLabel(name = "try_end"))
  insns.add(LGoto(label = "done"))

  insns.add(LLabel(name = "catch_ae")) // handler entry: exception on stack
  insns.add(LPop)                      // discard exception
  // result remains -1

  insns.add(LLabel(name = "done"))
  insns.add(LIload(slot = 2))
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  params.add(JInt)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "safeDivide",
    params    = params,
    ret       = JInt,
    insns     = insns,
    maxStack  = 2,
    maxLocals = 3
  )
}

func makeSafeMathBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(makeSafeDivideMethod(), pool))
  val cf = makeClassWithMethods("SafeMath", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx    = poolFieldref(pool,  "java/lang/System",    "out",         "Ljava/io/PrintStream;")
  val printlnIdx   = poolMethodref(pool, "java/io/PrintStream", "println",     "(Ljava/lang/String;)V")
  val concatIdx    = poolMethodref(pool, "java/lang/String",    "concat",      "(Ljava/lang/String;)Ljava/lang/String;")
  val valOfIIdx    = poolMethodref(pool, "java/lang/String",    "valueOf",     "(I)Ljava/lang/String;")
  val safeDivIdx   = poolMethodref(pool, "SafeMath",            "safeDivide",  "(II)I")

  // println("divide(10,2)=" + String.valueOf(SafeMath.safeDivide(10, 2)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "divide(10,2)=")
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, safeDivIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("divide(10,0)=" + String.valueOf(SafeMath.safeDivide(10, 0)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "divide(10,0)=")
  emitPushInt(asm, 10)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, safeDivIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b100"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val safeMathClass = BuiltClass(binaryName = "SafeMath", bytes = makeSafeMathBytes())
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(safeMathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB100",
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
