// jvm/self_test_b61.l — Stage B61: long add, i2l widening, l2i narrowing.
//
// Generates LongOps.class with:
//   addLongs(JJ)J   — a + b  (long add)
//   widenToLong(I)J — (long) i  (i2l widening)
//   narrowToInt(J)I — (int) n   (l2i narrowing)
//
// Main prints:
//   addLongs(5000000000L, 3000000000L) → 8000000000
//   widenToLong(-1)                    → -1
//   narrowToInt(2147483647L)           → 2147483647
//
// Exercises: lload, ladd, lreturn, i2l, l2i; complements B26 (lmul+ldc2_w).

package Jvm.SelfTestB61

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeLongOpsBytes(): List[Byte] {
  val pool = poolNew()

  // addLongs(JJ)J  — slot 0+1=a, slot 2+3=b
  val asmAdd = newAssembler(pool)
  emitLload(asmAdd, 0)
  emitLload(asmAdd, 2)
  emitLadd(asmAdd)
  emitLreturn(asmAdd)
  val addCode = assembleCode(asmAdd, 4, 4)
  val addAttrs: List[Attribute] = newList()
  addAttrs.add(addCode)
  val addMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "addLongs", "(JJ)J", addAttrs)

  // widenToLong(I)J  — slot 0=i (int)
  val asmWiden = newAssembler(pool)
  emitIload(asmWiden, 0)
  emitI2l(asmWiden)
  emitLreturn(asmWiden)
  val widenCode = assembleCode(asmWiden, 2, 1)
  val widenAttrs: List[Attribute] = newList()
  widenAttrs.add(widenCode)
  val widenMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "widenToLong", "(I)J", widenAttrs)

  // narrowToInt(J)I  — slot 0+1=n (long)
  val asmNarrow = newAssembler(pool)
  emitLload(asmNarrow, 0)
  emitL2i(asmNarrow)
  emitIreturn(asmNarrow)
  val narrowCode = assembleCode(asmNarrow, 2, 2)
  val narrowAttrs: List[Attribute] = newList()
  narrowAttrs.add(narrowCode)
  val narrowMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "narrowToInt", "(J)I", narrowAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(addMethod)
  methods.add(widenMethod)
  methods.add(narrowMethod)
  val cf = makeClassWithMethods("LongOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnJ  = poolMethodref(pool, "java/io/PrintStream", "println", "(J)V")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val addRef    = poolMethodref(pool, "LongOps", "addLongs",    "(JJ)J")
  val widenRef  = poolMethodref(pool, "LongOps", "widenToLong", "(I)J")
  val narrowRef = poolMethodref(pool, "LongOps", "narrowToInt", "(J)I")

  // println(LongOps.addLongs(5000000000L, 3000000000L)) → 8000000000
  emitGetstatic(asm, sysOut)
  emitPushLong(asm, 5000000000i64)
  emitPushLong(asm, 3000000000i64)
  emitInvokestatic(asm, addRef)
  emitInvokevirtual(asm, printlnJ)

  // println(LongOps.widenToLong(-1)) → -1
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -1)
  emitInvokestatic(asm, widenRef)
  emitInvokevirtual(asm, printlnJ)

  // println(LongOps.narrowToInt(2147483647L)) → 2147483647
  emitGetstatic(asm, sysOut)
  emitPushLong(asm, 2147483647i64)
  emitInvokestatic(asm, narrowRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+pushLong(3)+pushLong(5) = 5 peak for addLongs
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
  val outDir = "/tmp/lyric-jvm-b61"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val longOpsBytes = makeLongOpsBytes()
  val mainBytes    = makeMainClassBytes()

  val longOpsClass = BuiltClass(binaryName = "LongOps", bytes = longOpsBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(longOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB61",
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
