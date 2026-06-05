//! jvm/self_test_b78.l — Stage B78: long[] arrays (newarray T_LONG, laload, lastore).
//!
//! Generates LongArrays.class with:
//!   makeLongs()[J   — builds {1000000000, 2000000000, 3000000000} via lastore
//!   sumLongs([J)J   — sums elements via laload
//!   getAt([JI)J     — returns element at index
//!
//! Main prints:
//!   sum=6000000000
//!   at1=2000000000
//!
//! Exercises: newarray T_LONG, lastore, laload, lreturn, ldc2_w, arraylength.
package Jvm.SelfTestB78

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeLongArraysBytes(): List[Byte] {
  val pool = poolNew()

  // makeLongs()[J — {1000000000L, 2000000000L, 3000000000L}
  val asmMake = newAssembler(pool)
  emitPushInt(asmMake, 3)
  emitNewarray(asmMake, T_LONG)
  emitAstore(asmMake, 0)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 0)
  emitPushLong(asmMake, 1000000000i64)
  emitLastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 1)
  emitPushLong(asmMake, 2000000000i64)
  emitLastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 2)
  emitPushLong(asmMake, 3000000000i64)
  emitLastore(asmMake)
  emitAload(asmMake, 0)
  emitAreturn(asmMake)
  val makeCode = assembleCode(asmMake, 4, 1)
  val makeAttrs: List[Attribute] = newList()
  makeAttrs.add(makeCode)
  val makeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeLongs", "()[J", makeAttrs)

  // sumLongs([J)J — slot 0=arr; slot 1+2=sum=0L; slot 3=i=0; slot 4=len
  val asmSum = newAssembler(pool)
  emitPushLong(asmSum, 0i64)
  emitLstore(asmSum, 1)
  emitAload(asmSum, 0)
  emitArraylength(asmSum)
  emitIstore(asmSum, 4)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 3)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 3)
  emitIload(asmSum, 4)
  emitIfIcmpge(asmSum, "SUM_DONE")
  emitLload(asmSum, 1)
  emitAload(asmSum, 0)
  emitIload(asmSum, 3)
  emitLaload(asmSum)
  emitLadd(asmSum)
  emitLstore(asmSum, 1)
  emitIinc(asmSum, 3, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitLload(asmSum, 1)
  emitLreturn(asmSum)
  val sumCode = assembleCode(asmSum, 4, 5)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumLongs", "([J)J", sumAttrs)

  // getAt([JI)J — arr[idx]  slot 0=arr; slot 1=idx
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitIload(asmGet, 1)
  emitLaload(asmGet)
  emitLreturn(asmGet)
  val getCode = assembleCode(asmGet, 3, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getAt", "([JI)J", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethod)
  methods.add(sumMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethodsV49("LongArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfJ = poolMethodref(pool, "java/lang/String", "valueOf", "(J)Ljava/lang/String;")
  val makeRef = poolMethodref(pool, "LongArrays", "makeLongs", "()[J")
  val sumRef = poolMethodref(pool, "LongArrays", "sumLongs", "([J)J")
  val getRef = poolMethodref(pool, "LongArrays", "getAt", "([JI)J")

  // arr = LongArrays.makeLongs()   (slot 0)
  emitInvokestatic(asm, makeRef)
  emitAstore(asm, 0)

  // println("sum=" + String.valueOf(sumLongs(makeLongs())))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "sum=")
  emitInvokestatic(asm, makeRef)
  emitInvokestatic(asm, sumRef)
  emitInvokestatic(asm, valueOfJ)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("at1=" + String.valueOf(getAt(arr, 1)))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "at1=")
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitInvokestatic(asm, getRef)
  emitInvokestatic(asm, valueOfJ)
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
  val outDir = "/tmp/lyric-jvm-b78"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val longArraysBytes = makeLongArraysBytes()
  val mainBytes = makeMainClassBytes()

  val longArraysClass = BuiltClass(binaryName = "LongArrays", bytes = longArraysBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(longArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB78",
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
