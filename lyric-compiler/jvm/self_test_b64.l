// jvm/self_test_b64.l — Stage B64: iinc (increment local variable in-place).
//
// Generates Loops.class with two static methods:
//   sumTo(I)I    — sum 1..n using iinc for the loop counter
//   countDown(I)I — count down from n to 0 using iinc with negative delta
//
// Main prints:
//   sumTo(10)    → 55
//   countDown(5) → 0
//
// Exercises: iinc with positive and negative deltas (the wide form
//            is covered implicitly if slot > 255 but here slot is small).

package Jvm.SelfTestB64

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeLoopsBytes(): List[Byte] {
  val pool = poolNew()

  // sumTo(I)I
  // slot 0 = n (param), slot 1 = total (0), slot 2 = i (1)
  // INIT:  iconst_0, istore_1, iconst_1, istore_2
  // LOOP:  iload_2, iload_0, if_icmpgt DONE
  //        iload_1, iload_2, iadd, istore_1
  //        iinc 2, 1
  //        goto LOOP
  // DONE:  iload_1, ireturn
  val asmSum = newAssembler(pool)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 1)
  emitIconst(asmSum, 1)
  emitIstore(asmSum, 2)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 2)
  emitIload(asmSum, 0)
  emitIfIcmpgt(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitIload(asmSum, 2)
  emitIadd(asmSum)
  emitIstore(asmSum, 1)
  emitIinc(asmSum, 2, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitIreturn(asmSum)
  val sumCode = assembleCode(asmSum, 2, 3)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumTo", "(I)I", sumAttrs)

  // countDown(I)I
  // slot 0 = n (param), counts down in place to 0
  // LOOP: iload_0, ifeq DONE
  //       iinc 0, -1
  //       goto LOOP
  // DONE: iload_0, ireturn
  val asmDown = newAssembler(pool)
  emitLabel(asmDown, "DOWN_LOOP")
  emitIload(asmDown, 0)
  emitIfeq(asmDown, "DOWN_DONE")
  emitIinc(asmDown, 0, -1)
  emitGoto(asmDown, "DOWN_LOOP")
  emitLabel(asmDown, "DOWN_DONE")
  emitIload(asmDown, 0)
  emitIreturn(asmDown)
  val downCode = assembleCode(asmDown, 1, 1)
  val downAttrs: List[Attribute] = newList()
  downAttrs.add(downCode)
  val downMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "countDown", "(I)I", downAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(sumMethod)
  methods.add(downMethod)
  val cf = makeClassWithMethodsV49("Loops", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool     = poolNew()
  val asm      = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val sumRef   = poolMethodref(pool, "Loops", "sumTo",     "(I)I")
  val downRef  = poolMethodref(pool, "Loops", "countDown", "(I)I")

  // println(Loops.sumTo(10))    → 55
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, sumRef)
  emitInvokevirtual(asm, printlnI)

  // println(Loops.countDown(5)) → 0
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, downRef)
  emitInvokevirtual(asm, printlnI)

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
  val outDir = "/tmp/lyric-jvm-b64"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val loopsBytes = makeLoopsBytes()
  val mainBytes  = makeMainClassBytes()

  val loopsClass = BuiltClass(binaryName = "Loops", bytes = loopsBytes)
  val mainClass  = BuiltClass(binaryName = "Main",  bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(loopsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB64",
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
