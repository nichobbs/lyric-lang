// jvm/self_test_b77.l — Stage B77: short[] arrays (newarray T_SHORT, saload, sastore).
//
// Generates ShortArrays.class with:
//   makeShorts()[S  — builds {100, 200, 300} via sastore
//   sumShorts([S)I  — sums elements via saload
//   getAt([SI)I     — returns element at index
//
// Main prints:
//   sum=600
//   at1=200
//
// Exercises: newarray T_SHORT, sastore, saload, arraylength, iinc.

package Jvm.SelfTestB77

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeShortArraysBytes(): List[Byte] {
  val pool = poolNew()

  // makeShorts()[S — {100, 200, 300}
  val asmMake = newAssembler(pool)
  emitPushInt(asmMake, 3)
  emitNewarray(asmMake, T_SHORT)
  emitAstore(asmMake, 0)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 0)
  emitPushInt(asmMake, 100)
  emitSastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 1)
  emitPushInt(asmMake, 200)
  emitSastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 2)
  emitPushInt(asmMake, 300)
  emitSastore(asmMake)
  emitAload(asmMake, 0)
  emitAreturn(asmMake)
  val makeCode = assembleCode(asmMake, 3, 1)
  val makeAttrs: List[Attribute] = newList()
  makeAttrs.add(makeCode)
  val makeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeShorts", "()[S", makeAttrs)

  // sumShorts([S)I — slot 0=arr; slot 1=sum=0; slot 2=i=0; slot 3=len
  val asmSum = newAssembler(pool)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 1)
  emitAload(asmSum, 0)
  emitArraylength(asmSum)
  emitIstore(asmSum, 3)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 2)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 2)
  emitIload(asmSum, 3)
  emitIfIcmpge(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitAload(asmSum, 0)
  emitIload(asmSum, 2)
  emitSaload(asmSum)
  emitIadd(asmSum)
  emitIstore(asmSum, 1)
  emitIinc(asmSum, 2, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitIreturn(asmSum)
  val sumCode = assembleCode(asmSum, 3, 4)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumShorts", "([S)I", sumAttrs)

  // getAt([SI)I — arr[idx]
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitIload(asmGet, 1)
  emitSaload(asmGet)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 2, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getAt", "([SI)I", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethod)
  methods.add(sumMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethodsV49("ShortArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfI  = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val makeRef   = poolMethodref(pool, "ShortArrays", "makeShorts", "()[S")
  val sumRef    = poolMethodref(pool, "ShortArrays", "sumShorts",  "([S)I")
  val getRef    = poolMethodref(pool, "ShortArrays", "getAt",      "([SI)I")

  // arr = ShortArrays.makeShorts()
  emitInvokestatic(asm, makeRef)
  emitAstore(asm, 0)

  // println("sum=" + ShortArrays.sumShorts(arr))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "sum=")
  emitInvokestatic(asm, makeRef)
  emitInvokestatic(asm, sumRef)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("at1=" + ShortArrays.getAt(arr, 1))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "at1=")
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitInvokestatic(asm, getRef)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

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
  val outDir = "/tmp/lyric-jvm-b77"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val shortArraysBytes = makeShortArraysBytes()
  val mainBytes        = makeMainClassBytes()

  val shortArraysClass = BuiltClass(binaryName = "ShortArrays", bytes = shortArraysBytes)
  val mainClass        = BuiltClass(binaryName = "Main",        bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(shortArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB77",
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
