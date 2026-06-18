//! jvm/self_test_b60.l — Stage B60: java.lang.Math static methods.
//!
//! Generates MathHelper.class with:
//!   absInt(I)I      — Math.abs(i)
//!   minInt(II)I     — Math.min(a, b)
//!   maxInt(II)I     — Math.max(a, b)
//!
//! Main prints:
//!   absInt(-7)      → 7
//!   minInt(3, 8)    → 3
//!   maxInt(3, 8)    → 8
//!
//! Exercises: invokestatic on java/lang/Math for abs/min/max builtins.
package Jvm.SelfTestB60

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathHelperBytes(): List[Byte] {
  val pool = poolNew()
  val absRef = poolMethodref(pool, "java/lang/Math", "abs", "(I)I")
  val minRef = poolMethodref(pool, "java/lang/Math", "min", "(II)I")
  val maxRef = poolMethodref(pool, "java/lang/Math", "max", "(II)I")

  // absInt(I)I
  val asmAbs = newAssembler(pool)
  emitIload(asmAbs, 0)
  emitInvokestatic(asmAbs, absRef)
  emitIreturn(asmAbs)
  val absCode = assembleCode(asmAbs, 1, 1)
  val absAttrs: List[Attribute] = newList()
  absAttrs.add(absCode)
  val absMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "absInt", "(I)I", absAttrs)

  // minInt(II)I
  val asmMin = newAssembler(pool)
  emitIload(asmMin, 0)
  emitIload(asmMin, 1)
  emitInvokestatic(asmMin, minRef)
  emitIreturn(asmMin)
  val minCode = assembleCode(asmMin, 2, 2)
  val minAttrs: List[Attribute] = newList()
  minAttrs.add(minCode)
  val minMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "minInt", "(II)I", minAttrs)

  // maxInt(II)I
  val asmMax = newAssembler(pool)
  emitIload(asmMax, 0)
  emitIload(asmMax, 1)
  emitInvokestatic(asmMax, maxRef)
  emitIreturn(asmMax)
  val maxCode = assembleCode(asmMax, 2, 2)
  val maxAttrs: List[Attribute] = newList()
  maxAttrs.add(maxCode)
  val maxMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "maxInt", "(II)I", maxAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(absMethod)
  methods.add(minMethod)
  methods.add(maxMethod)
  val cf = makeClassWithMethods("MathHelper", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val absRef = poolMethodref(pool, "MathHelper", "absInt", "(I)I")
  val minRef = poolMethodref(pool, "MathHelper", "minInt", "(II)I")
  val maxRef = poolMethodref(pool, "MathHelper", "maxInt", "(II)I")

  // println(MathHelper.absInt(-7))  → 7
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -7)
  emitInvokestatic(asm, absRef)
  emitInvokevirtual(asm, printlnI)

  // println(MathHelper.minInt(3, 8)) → 3
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 3)
  emitPushInt(asm, 8)
  emitInvokestatic(asm, minRef)
  emitInvokevirtual(asm, printlnI)

  // println(MathHelper.maxInt(3, 8)) → 8
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 3)
  emitPushInt(asm, 8)
  emitInvokestatic(asm, maxRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+push3(2)+push8(3) = 3 peak for min/max calls
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
  val outDir = "/tmp/lyric-jvm-b60"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val mathHelperBytes = makeMathHelperBytes()
  val mainBytes = makeMainClassBytes()

  val mathHelperClass = BuiltClass(binaryName = "MathHelper", bytes = mathHelperBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathHelperClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB60",
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
