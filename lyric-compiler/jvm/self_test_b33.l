// jvm/self_test_b33.l — Stage B33: dcmpg for double sign comparison.
//
// Generates DoubleSign.class with static sign(D)I that uses dcmpg:
//   dload_0; dconst_0; dcmpg → -1 if d < 0 (or NaN), 0 if d == 0, 1 if d > 0
//
// Main prints:
//   sign(-3.5) = -1
//   sign(0.0)  =  0
//   sign(7.2)  =  1
//
// Linear method body (no branches), no StackMapTable needed.

package Jvm.SelfTestB33

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeDoubleSignClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // sign(D)I
  //   dload_0       (the double arg — occupies slots 0-1)
  //   dconst_0      (push 0.0)
  //   dcmpg         (compare: -1/0/1)
  //   ireturn
  emitDload(asm, 0)
  emitDconst(asm, 0)
  emitDcmpg(asm)
  emitIreturn(asm)

  val codeAttr = assembleCode(asm, 4, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val signMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sign", "(D)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(signMethod)
  val cf = makeClassWithMethods("DoubleSign", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val signRef   = poolMethodref(pool, "DoubleSign", "sign", "(D)I")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // sign(-3.5) = -1
  emitGetstatic(asm, sysOut)
  emitPushDouble(asm, -3.5)
  emitInvokestatic(asm, signRef)
  emitInvokevirtual(asm, printlnI)

  // sign(0.0) = 0
  emitGetstatic(asm, sysOut)
  emitDconst(asm, 0)
  emitInvokestatic(asm, signRef)
  emitInvokevirtual(asm, printlnI)

  // sign(7.2) = 1
  emitGetstatic(asm, sysOut)
  emitPushDouble(asm, 7.2)
  emitInvokestatic(asm, signRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // max_stack: ps + double(2) = 3
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
  val outDir = "/tmp/lyric-jvm-b33"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val doubleSignBytes = makeDoubleSignClassBytes()
  val mainBytes       = makeMainClassBytes()

  val doubleSignClass = BuiltClass(binaryName = "DoubleSign", bytes = doubleSignBytes)
  val mainClass       = BuiltClass(binaryName = "Main",       bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(doubleSignClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB33",
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
