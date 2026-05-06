// jvm/self_test_b23.l — Stage B23: primitive arrays (newarray, iastore, iaload, arraylength).
//
// Generates ArrayUtil.class with a static sumFirst3() method that:
//   1. Creates a new int[] of length 3
//   2. Stores values 10, 20, 30 at indices 0, 1, 2
//   3. Loops over the array summing elements
//   4. Returns the sum (60)
//
// Exercises: newarray T_INT, dup, arraylength, iastore, iaload, backward loop.
// Uses assembleCodeWithFrames for the backward loop (major=65 class file).

package Jvm.SelfTestB23

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeArrayUtilClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // sumFirst3()I:
  //   slot 0 = int[] arr
  //   slot 1 = int   sum
  //   slot 2 = int   i (loop variable)
  //
  //   newarray T_INT, 3  → arr
  //   astore_0
  //
  //   aload_0; iconst_0; bipush 10; iastore   // arr[0] = 10
  //   aload_0; iconst_1; bipush 20; iastore   // arr[1] = 20
  //   aload_0; iconst_2; bipush 30; iastore   // arr[2] = 30
  //
  //   iconst_0; istore_1   // sum = 0
  //   iconst_0; istore_2   // i = 0
  //
  // loopHead:
  //   iload_2; aload_0; arraylength; if_icmpge "done"
  //   iload_1; aload_0; iload_2; iaload; iadd; istore_1   // sum += arr[i]
  //   iinc_2_1 (or iload_2; iconst_1; iadd; istore_2)     // i++
  //   goto loopHead
  //
  // done:
  //   iload_1; ireturn

  emitPushInt(asm, 3)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 0)

  emitAload(asm, 0)
  emitPushInt(asm, 0)
  emitPushInt(asm, 10)
  emitIastore(asm)

  emitAload(asm, 0)
  emitPushInt(asm, 1)
  emitPushInt(asm, 20)
  emitIastore(asm)

  emitAload(asm, 0)
  emitPushInt(asm, 2)
  emitPushInt(asm, 30)
  emitIastore(asm)

  emitPushInt(asm, 0)
  emitIstore(asm, 1)
  emitPushInt(asm, 0)
  emitIstore(asm, 2)

  emitLabel(asm, "loopHead")
  emitIload(asm, 2)
  emitAload(asm, 0)
  emitArraylength(asm)
  emitIfIcmpge(asm, "done")

  emitIload(asm, 1)
  emitAload(asm, 0)
  emitIload(asm, 2)
  emitIaload(asm)
  emitIadd(asm)
  emitIstore(asm, 1)

  emitIload(asm, 2)
  emitPushInt(asm, 1)
  emitIadd(asm)
  emitIstore(asm, 2)

  emitGoto(asm, "loopHead")

  emitLabel(asm, "done")
  emitIload(asm, 1)
  emitIreturn(asm)

  // Frame at both labels: [VObject("int[]"), VInteger, VInteger]
  // Slot 0 = int[] (VObject with descriptor "[I")
  // Slot 1 = int sum
  // Slot 2 = int i
  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VObject(className = "[I"))
  frameLocals.add(VInteger)
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 3, 3, frameLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumFirst3", "()I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(sumMethod)
  val cf = makeClassWithMethods("ArrayUtil", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val sumRef   = poolMethodref(pool, "ArrayUtil", "sumFirst3", "()I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, sumRef)
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
  val outDir = "/tmp/lyric-jvm-b23"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val arrayUtilBytes = makeArrayUtilClassBytes()
  val mainBytes      = makeMainClassBytes()

  val arrayUtilClass = BuiltClass(binaryName = "ArrayUtil", bytes = arrayUtilBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(arrayUtilClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB23",
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
