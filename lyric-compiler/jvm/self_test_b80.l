//! jvm/self_test_b80.l — Stage B80: System.arraycopy (native bulk array copy).
//!
//! Generates ArrayCopy.class with:
//!   copyRange(int[], int, int, int)int[]
//!     — allocates dst[len], calls System.arraycopy(src,srcPos,dst,0,len), returns dst
//!   concat(int[], int[])int[]
//!     — allocates dst[a.length+b.length], copies a then b
//!
//! Main prints:
//!   copy=2,3,4
//!   cat=1,2,3,4,5
//!
//! Exercises: System.arraycopy (invokestatic with 5 args), arraylength,
//!            newarray T_INT, iaload for printing.
package Jvm.SelfTestB80

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeArrayCopyBytes(): List[Byte] {
  val pool = poolNew()

  val sysArraycopy = poolMethodref(pool, "java/lang/System", "arraycopy", "(Ljava/lang/Object;ILjava/lang/Object;II)V")

  // copyRange(int[] src, int srcPos, int len)int[]
  // slot 0=src; slot 1=srcPos; slot 2=len; slot 3=dst
  val asmCR = newAssembler(pool)
  emitIload(asmCR, 2)
  emitNewarray(asmCR, T_INT)
  emitAstore(asmCR, 3)
  // System.arraycopy(src, srcPos, dst, 0, len)
  emitAload(asmCR, 0)
  emitIload(asmCR, 1)
  emitAload(asmCR, 3)
  emitIconst(asmCR, 0)
  emitIload(asmCR, 2)
  emitInvokestatic(asmCR, sysArraycopy)
  emitAload(asmCR, 3)
  emitAreturn(asmCR)
  val crCode = assembleCode(asmCR, 5, 4)
  val crAttrs: List[Attribute] = newList()
  crAttrs.add(crCode)
  val crMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "copyRange", "([III)[I", crAttrs)

  // concat(int[] a, int[] b)int[]
  // slot 0=a; slot 1=b; slot 2=la; slot 3=lb; slot 4=dst
  val asmCat = newAssembler(pool)
  emitAload(asmCat, 0)
  emitArraylength(asmCat)
  emitIstore(asmCat, 2)
  emitAload(asmCat, 1)
  emitArraylength(asmCat)
  emitIstore(asmCat, 3)
  emitIload(asmCat, 2)
  emitIload(asmCat, 3)
  emitIadd(asmCat)
  emitNewarray(asmCat, T_INT)
  emitAstore(asmCat, 4)
  // System.arraycopy(a, 0, dst, 0, la)
  emitAload(asmCat, 0)
  emitIconst(asmCat, 0)
  emitAload(asmCat, 4)
  emitIconst(asmCat, 0)
  emitIload(asmCat, 2)
  emitInvokestatic(asmCat, sysArraycopy)
  // System.arraycopy(b, 0, dst, la, lb)
  emitAload(asmCat, 1)
  emitIconst(asmCat, 0)
  emitAload(asmCat, 4)
  emitIload(asmCat, 2)
  emitIload(asmCat, 3)
  emitInvokestatic(asmCat, sysArraycopy)
  emitAload(asmCat, 4)
  emitAreturn(asmCat)
  val catCode = assembleCode(asmCat, 5, 5)
  val catAttrs: List[Attribute] = newList()
  catAttrs.add(catCode)
  val catMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "concat", "([I[I)[I", catAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(crMethod)
  methods.add(catMethod)
  val cf = makeClassWithMethods("ArrayCopy", methods)
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
  val copyRef = poolMethodref(pool, "ArrayCopy", "copyRange", "([III)[I")
  val catRef = poolMethodref(pool, "ArrayCopy", "concat", "([I[I)[I")

  // Build src = {1,2,3,4,5}  (slot 0)
  emitPushInt(asm, 5)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 0)
  emitAload(asm, 0)
  emitIconst(asm, 0)
  emitIconst(asm, 1)
  emitIastore(asm)
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitPushInt(asm, 2)
  emitIastore(asm)
  emitAload(asm, 0)
  emitIconst(asm, 2)
  emitPushInt(asm, 3)
  emitIastore(asm)
  emitAload(asm, 0)
  emitIconst(asm, 3)
  emitPushInt(asm, 4)
  emitIastore(asm)
  emitAload(asm, 0)
  emitIconst(asm, 4)
  emitPushInt(asm, 5)
  emitIastore(asm)

  // copy = copyRange(src, 1, 3)  slot 1
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitIconst(asm, 3)
  emitInvokestatic(asm, copyRef)
  emitAstore(asm, 1)

  // Build a={1,2,3} b={4,5} (slots 2, 3)
  emitPushInt(asm, 3)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 2)
  emitAload(asm, 2)
  emitIconst(asm, 0)
  emitIconst(asm, 1)
  emitIastore(asm)
  emitAload(asm, 2)
  emitIconst(asm, 1)
  emitPushInt(asm, 2)
  emitIastore(asm)
  emitAload(asm, 2)
  emitIconst(asm, 2)
  emitPushInt(asm, 3)
  emitIastore(asm)

  emitPushInt(asm, 2)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 3)
  emitAload(asm, 3)
  emitIconst(asm, 0)
  emitPushInt(asm, 4)
  emitIastore(asm)
  emitAload(asm, 3)
  emitIconst(asm, 1)
  emitPushInt(asm, 5)
  emitIastore(asm)

  // cat = concat(a, b)  slot 4
  emitAload(asm, 2)
  emitAload(asm, 3)
  emitInvokestatic(asm, catRef)
  emitAstore(asm, 4)

  // print "copy=2,3,4": copy[0]+","+copy[1]+","+copy[2]
  emitGetstatic(asm, sysOut)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitPushString(asm, "copy=")
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
  emitPushInt(asm, 2)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitInvokevirtual(asm, sbToStr)
  emitInvokevirtual(asm, printlnS)

  // print "cat=1,2,3,4,5"
  emitGetstatic(asm, sysOut)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitPushString(asm, "cat=")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 4)
  emitIconst(asm, 0)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 4)
  emitIconst(asm, 1)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 4)
  emitIconst(asm, 2)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 4)
  emitIconst(asm, 3)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",")
  emitInvokevirtual(asm, sbAppendS)
  emitAload(asm, 4)
  emitIconst(asm, 4)
  emitIaload(asm)
  emitInvokevirtual(asm, sbAppendI)
  emitInvokevirtual(asm, sbToStr)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 8, 5)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b80"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val arrayCopyBytes = makeArrayCopyBytes()
  val mainBytes = makeMainClassBytes()

  val arrayCopyClass = BuiltClass(binaryName = "ArrayCopy", bytes = arrayCopyBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(arrayCopyClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB80",
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
