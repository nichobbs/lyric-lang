// jvm/self_test_b75.l — Stage B75: byte[] arrays (newarray T_BYTE, baload, bastore).
//
// Generates ByteArrays.class with:
//   makeBytes(I)byte[]    — allocates byte[n], fills [0..n-1] with (byte)i
//   sumBytes(byte[])I     — sums all elements (baload, sign-extended to int)
//   getAt(byte[],I)I      — returns arr[i] as int
//
// Main prints:
//   getAt(makeBytes(4), 2) → 2
//   sumBytes(makeBytes(4)) → 6  (0+1+2+3)
//
// Exercises: newarray T_BYTE, bastore (store int as byte), baload, arraylength,
//            iinc loop counter.

package Jvm.SelfTestB75

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeByteArraysBytes(): List[Byte] {
  val pool = poolNew()

  // makeBytes(I)byte[]
  // slot 0=n; slot 1=arr; slot 2=i
  // arr = new byte[n]
  // i=0; LOOP: if i>=n goto DONE; arr[i]=(byte)i; iinc 2,1; goto LOOP; DONE: return arr
  val asmMake = newAssembler(pool)
  emitIload(asmMake, 0)
  emitNewarray(asmMake, T_BYTE)
  emitAstore(asmMake, 1)
  emitIconst(asmMake, 0)
  emitIstore(asmMake, 2)
  emitLabel(asmMake, "MAKE_LOOP")
  emitIload(asmMake, 2)
  emitIload(asmMake, 0)
  emitIfIcmpge(asmMake, "MAKE_DONE")
  emitAload(asmMake, 1)
  emitIload(asmMake, 2)
  emitIload(asmMake, 2)
  emitBastore(asmMake)
  emitIinc(asmMake, 2, 1)
  emitGoto(asmMake, "MAKE_LOOP")
  emitLabel(asmMake, "MAKE_DONE")
  emitAload(asmMake, 1)
  emitAreturn(asmMake)
  // maxStack: aload(1)+iload(2)+iload(3) for bastore = 3 peak
  val makeCode = assembleCode(asmMake, 3, 3)
  val makeAttrs: List[Attribute] = newList()
  makeAttrs.add(makeCode)
  val makeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeBytes", "(I)[B", makeAttrs)

  // sumBytes(byte[])I
  // slot 0=arr; slot 1=sum=0; slot 2=i=0
  val asmSum = newAssembler(pool)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 1)
  emitIconst(asmSum, 0)
  emitIstore(asmSum, 2)
  emitLabel(asmSum, "SUM_LOOP")
  emitIload(asmSum, 2)
  emitAload(asmSum, 0)
  emitArraylength(asmSum)
  emitIfIcmpge(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitAload(asmSum, 0)
  emitIload(asmSum, 2)
  emitBaload(asmSum)
  emitIadd(asmSum)
  emitIstore(asmSum, 1)
  emitIinc(asmSum, 2, 1)
  emitGoto(asmSum, "SUM_LOOP")
  emitLabel(asmSum, "SUM_DONE")
  emitIload(asmSum, 1)
  emitIreturn(asmSum)
  val sumCode = assembleCode(asmSum, 3, 3)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sumBytes", "([B)I", sumAttrs)

  // getAt(byte[],I)I
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitIload(asmGet, 1)
  emitBaload(asmGet)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 2, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getAt", "([BI)I", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethod)
  methods.add(sumMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethodsV49("ByteArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val makeRef   = poolMethodref(pool, "ByteArrays", "makeBytes", "(I)[B")
  val sumRef    = poolMethodref(pool, "ByteArrays", "sumBytes",  "([B)I")
  val getRef    = poolMethodref(pool, "ByteArrays", "getAt",     "([BI)I")

  // arr = ByteArrays.makeBytes(4)
  emitPushInt(asm, 4)
  emitInvokestatic(asm, makeRef)
  emitAstore(asm, 0)

  // println(ByteArrays.getAt(arr, 2)) → 2
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, getRef)
  emitInvokevirtual(asm, printlnI)

  // println(ByteArrays.sumBytes(arr)) → 6
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, sumRef)
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
  val outDir = "/tmp/lyric-jvm-b75"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val byteArraysBytes = makeByteArraysBytes()
  val mainBytes       = makeMainClassBytes()

  val byteArraysClass = BuiltClass(binaryName = "ByteArrays", bytes = byteArraysBytes)
  val mainClass       = BuiltClass(binaryName = "Main",       bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(byteArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB75",
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
