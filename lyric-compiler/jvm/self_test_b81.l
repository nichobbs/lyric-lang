//! jvm/self_test_b81.l — Stage B81: Arrays.fill (java.util.Arrays.fill(int[],int)).
//!
//! Generates Filler.class with:
//!   makeAndFill(int n, int val)int[]  — new int[n]; Arrays.fill(arr, val); return arr
//!   fillRange(int[] arr, int from, int to, int val)void
//!     — Arrays.fill(arr, from, to, val)
//!
//! Main prints:
//!   fill=7,7,7,7,7
//!   range=0,9,9,9,0
//!
//! Exercises: java.util.Arrays.fill(int[],int) and fill(int[],int,int,int).
package Jvm.SelfTestB81

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFillerBytes(): List[Byte] {
  val pool = poolNew()

  val arraysFill = poolMethodref(pool, "java/util/Arrays", "fill", "([II)V")
  val arraysFillR = poolMethodref(pool, "java/util/Arrays", "fill", "([IIII)V")

  // makeAndFill(int n, int val)int[]  slot 0=n; slot 1=val; slot 2=arr
  val asmMF = newAssembler(pool)
  emitIload(asmMF, 0)
  emitNewarray(asmMF, T_INT)
  emitAstore(asmMF, 2)
  emitAload(asmMF, 2)
  emitIload(asmMF, 1)
  emitInvokestatic(asmMF, arraysFill)
  emitAload(asmMF, 2)
  emitAreturn(asmMF)
  val mfCode = assembleCode(asmMF, 2, 3)
  val mfAttrs: List[Attribute] = newList()
  mfAttrs.add(mfCode)
  val mfMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeAndFill", "(II)[I", mfAttrs)

  // fillRange(int[] arr, int from, int to, int val)void
  // slot 0=arr; slot 1=from; slot 2=to; slot 3=val
  val asmFR = newAssembler(pool)
  emitAload(asmFR, 0)
  emitIload(asmFR, 1)
  emitIload(asmFR, 2)
  emitIload(asmFR, 3)
  emitInvokestatic(asmFR, arraysFillR)
  emitReturn(asmFR)
  val frCode = assembleCode(asmFR, 4, 4)
  val frAttrs: List[Attribute] = newList()
  frAttrs.add(frCode)
  val frMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fillRange", "([IIII)V", frAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(mfMethod)
  methods.add(frMethod)
  val cf = makeClassWithMethods("Filler", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val sbInit = poolMethodref(pool, "java/lang/StringBuilder", "<init>", "()V")
  val sbClass = poolClass(pool, "java/lang/StringBuilder")
  val sbAppendS = poolMethodref(
    pool,
    "java/lang/StringBuilder",
    "append",
    "(Ljava/lang/String;)Ljava/lang/StringBuilder;"
  )
  val sbAppendI = poolMethodref(pool, "java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;")
  val sbToStr = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")
  val mfRef = poolMethodref(pool, "Filler", "makeAndFill", "(II)[I")
  val frRef = poolMethodref(pool, "Filler", "fillRange", "([IIII)V")

  // arr1 = Filler.makeAndFill(5, 7)  slot 0
  emitPushInt(asm, 5)
  emitPushInt(asm, 7)
  emitInvokestatic(asm, mfRef)
  emitAstore(asm, 0)

  // arr2 = {0,0,0,0,0} then fillRange(arr2, 1, 4, 9)  slot 1
  emitPushInt(asm, 5)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 1)
  emitAload(asm, 1)
  emitIconst(asm, 1)
  emitIconst(asm, 4)
  emitPushInt(asm, 9)
  emitInvokestatic(asm, frRef)

  // print "fill=7,7,7,7,7"
  emitGetstatic(asm, sysOut)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitPushString(asm, "fill=")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 0)
  emitIconst(asm, 0)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 0)
  emitIconst(asm, 2)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 0)
  emitIconst(asm, 3)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 0)
  emitIconst(asm, 4)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitInvokevirtual(asm, sbToStr)
  emitInvokevirtual(asm, printlnS)

  // print "range=0,9,9,9,0"
  emitGetstatic(asm, sysOut)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitPushString(asm, "range=")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 1)
  emitIconst(asm, 0)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 1)
  emitIconst(asm, 1)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 1)
  emitIconst(asm, 2)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 1)
  emitIconst(asm, 3)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 1)
  emitIconst(asm, 4)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitInvokevirtual(asm, sbToStr)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 8, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b81"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val fillerBytes = makeFillerBytes()
  val mainBytes = makeMainClassBytes()

  val fillerClass = BuiltClass(binaryName = "Filler", bytes = fillerBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(fillerClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB81",
    mainClass = "Main",
    version = "0.1.0",
    outPath = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
