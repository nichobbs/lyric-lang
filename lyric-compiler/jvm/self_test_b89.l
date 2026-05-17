// jvm/self_test_b89.l — Stage B89: float[] arrays (newarray T_FLOAT, faload, fastore).
//
// Generates FloatArrays.class with:
//   makeFloats()[F    — builds {1.5f, 2.5f, 3.5f} via fastore
//   sumFloats([F)F    — sums elements via faload
//   getAt([FI)F       — returns element at index
//
// Main prints:
//   sum=7.5
//   at1=2.5
//
// Exercises: newarray T_FLOAT, fastore, faload, fadd, freturn, ldc (float).

package Jvm.SelfTestB89

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFloatArraysBytes(): List[Byte] {
  val pool = poolNew()

  // makeFloats()[F — {1.5f, 2.5f, 3.5f}
  val asmMake = newAssembler(pool)
  emitPushInt(asmMake, 3)
  emitNewarray(asmMake, T_FLOAT)
  emitAstore(asmMake, 0)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 0)
  emitPushFloat(asmMake, 1.5)
  emitFastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 1)
  emitPushFloat(asmMake, 2.5)
  emitFastore(asmMake)
  emitAload(asmMake, 0)
  emitIconst(asmMake, 2)
  emitPushFloat(asmMake, 3.5)
  emitFastore(asmMake)
  emitAload(asmMake, 0)
  emitAreturn(asmMake)
  val makeCode = assembleCode(asmMake, 3, 1)
  val makeAttrs: List[Attribute] = newList()
  makeAttrs.add(makeCode)
  val makeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeFloats", "()[F", makeAttrs)

  // sumFloats([F)F — slot 0=arr; slot 1=sum; slot 2=i; slot 3=len
  val asmSum = newAssembler(pool)
  emitFconst0(asmSum)
  emitFstore(asmSum, 1)
  emitAload(asmSum, 0)
  emitArraylength(asmSum)
  emitIstore(asmSum, 3)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 2)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 2)
  emitIload(asmSum, 3)
  emitIfIcmpge(asmSum, "SUM_DONE")
  emitFload(asmSum, 1)
  emitAload(asmSum, 0)
  emitIload(asmSum, 2)
  emitFaload(asmSum)
  emitFadd(asmSum)
  emitFstore(asmSum, 1)
  emitIinc(asmSum, 2, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitFload(asmSum, 1)
  emitFreturn(asmSum)
  val sumCode = assembleCode(asmSum, 3, 4)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumFloats", "([F)F", sumAttrs)

  // getAt([FI)F — slot 0=arr; slot 1=idx
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitIload(asmGet, 1)
  emitFaload(asmGet)
  emitFreturn(asmGet)
  val getCode = assembleCode(asmGet, 2, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getAt", "([FI)F", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethod)
  methods.add(sumMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethodsV49("FloatArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfF  = poolMethodref(pool, "java/lang/String", "valueOf", "(F)Ljava/lang/String;")
  val makeRef   = poolMethodref(pool, "FloatArrays", "makeFloats", "()[F")
  val sumRef    = poolMethodref(pool, "FloatArrays", "sumFloats",  "([F)F")
  val getRef    = poolMethodref(pool, "FloatArrays", "getAt",      "([FI)F")

  // arr = FloatArrays.makeFloats()   (slot 0)
  emitInvokestatic(asm, makeRef)
  emitAstore(asm, 0)

  // println("sum=" + String.valueOf(sumFloats(makeFloats())))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "sum=")
  emitInvokestatic(asm, makeRef)
  emitInvokestatic(asm, sumRef)
  emitInvokestatic(asm, valueOfF)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("at1=" + String.valueOf(getAt(arr, 1)))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "at1=")
  emitAload(asm, 0)
  emitIconst(asm, 1)
  emitInvokestatic(asm, getRef)
  emitInvokestatic(asm, valueOfF)
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
  val outDir = "/tmp/lyric-jvm-b89"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val floatArraysBytes = makeFloatArraysBytes()
  val mainBytes        = makeMainClassBytes()

  val floatArraysClass = BuiltClass(binaryName = "FloatArrays", bytes = floatArraysBytes)
  val mainClass        = BuiltClass(binaryName = "Main",        bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(floatArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB89",
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
