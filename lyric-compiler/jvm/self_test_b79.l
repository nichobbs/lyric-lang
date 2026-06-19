//! jvm/self_test_b79.l — Stage B79: double[] arrays (newarray T_DOUBLE, daload, dastore).
//!
//! Generates DoubleArrays.class with:
//!   makeDoubles()[D  — builds {1.5, 2.5, 3.5} via dastore
//!   sumDoubles([D)D  — sums elements via daload
//!   getAt([DI)D      — returns element at index
//!
//! Main prints:
//!   sum=7.5
//!   at1=2.5
//!
//! Exercises: newarray T_DOUBLE, dastore, daload, dadd, dreturn, ldc2_w (double).
package Jvm.SelfTestB79

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeDoubleArraysBytes(): List[Byte] {
  val pool = poolNew()

  // makeDoubles()[D — {1.5, 2.5, 3.5}
  val asmMake = newAssembler(pool)
  emitPushInt(asmMake, 3)
  emitNewarray(asmMake, T_DOUBLE)
  emitAstore(asmMake, 0)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 0)
  emitPushDouble(asmMake, 1.5)
  emitDastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 1)
  emitPushDouble(asmMake, 2.5)
  emitDastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 2)
  emitPushDouble(asmMake, 3.5)
  emitDastore(asmMake)
  emitAload(asmMake, 0)
  emitAreturn(asmMake)
  val makeCode = assembleCode(asmMake, 5, 1)
  val makeAttrs: List[Attribute] = newList()
  makeAttrs.add(makeCode)
  val makeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeDoubles", "()[D", makeAttrs)

  // sumDoubles([D)D — slot 0=arr; slot 1+2=sum=0.0; slot 3=i=0; slot 4=len
  val asmSum = newAssembler(pool)
  emitDconst(asmSum, 0)
  emitDstore(asmSum, 1)
  emitAload(asmSum, 0)
  emitArraylength(asmSum)
  emitIstore(asmSum, 4)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 3)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 3)
  emitIload(asmSum, 4)
  emitIfIcmpge(asmSum, "SUM_DONE")
  emitDload(asmSum, 1)
  emitAload(asmSum, 0)
  emitIload(asmSum, 3)
  emitDaload(asmSum)
  emitDadd(asmSum)
  emitDstore(asmSum, 1)
  emitIinc(asmSum, 3, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitDload(asmSum, 1)
  emitDreturn(asmSum)
  val sumCode = assembleCode(asmSum, 4, 5)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumDoubles", "([D)D", sumAttrs)

  // getAt([DI)D — slot 0=arr; slot 1=idx
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitIload(asmGet, 1)
  emitDaload(asmGet)
  emitDreturn(asmGet)
  val getCode = assembleCode(asmGet, 3, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getAt", "([DI)D", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethod)
  methods.add(sumMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethodsV49("DoubleArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfD = poolMethodref(pool, "java/lang/String", "valueOf", "(D)Ljava/lang/String;")
  val makeRef = poolMethodref(pool, "DoubleArrays", "makeDoubles", "()[D")
  val sumRef = poolMethodref(pool, "DoubleArrays", "sumDoubles", "([D)D")
  val getRef = poolMethodref(pool, "DoubleArrays", "getAt", "([DI)D")

  // arr = DoubleArrays.makeDoubles()   (slot 0)
  emitInvokestatic(asm, makeRef)
  emitAstore(asm, 0)

  // println("sum=" + String.valueOf(sumDoubles(makeDoubles())))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "sum=")
  emitInvokestatic(asm, makeRef)
  emitInvokestatic(asm, sumRef)
  emitInvokestatic(asm, valueOfD)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("at1=" + String.valueOf(getAt(arr, 1)))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "at1=")
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitInvokestatic(asm, getRef)
  emitInvokestatic(asm, valueOfD)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b79"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val doubleArraysBytes = makeDoubleArraysBytes()
  val mainBytes = makeMainClassBytes()

  val doubleArraysClass = BuiltClass(binaryName = "DoubleArrays", bytes = doubleArraysBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(doubleArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB79",
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
