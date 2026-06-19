//! jvm/self_test_b46.l — Stage B46: float arithmetic (fadd, fmul, fdiv, i2f, f2d).
//!
//! Generates FloatMath.class with two static helpers:
//!   half(I)D  — converts int to float, divides by 2.0f, returns as double
//!   double_(I)D — converts int to float, multiplies by 2.0f, returns as double
//!
//! Main prints:
//!   half(5)    → 2.5
//!   double_(3) → 6.0
//!
//! Exercises: emitFconst2, emitFdiv, emitFmul, emitI2f, emitF2d, emitFreturn-via-f2d+dreturn.
package Jvm.SelfTestB46

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFloatMathClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── half(I)D ─────────────────────────────────────────────────────────────────
  // slot 0 = n (int)
  // iload_0; i2f; fconst_2; fdiv; f2d; dreturn
  val asmHalf = newAssembler(pool)
  emitIload(asmHalf, 0)
  emitI2f(asmHalf)
  emitFconst2(asmHalf)
  emitFdiv(asmHalf)
  emitF2d(asmHalf)
  emitDreturn(asmHalf)
  val halfCode = assembleCode(asmHalf, 2, 1)
  val halfAttrs: List[Attribute] = newList()
  halfAttrs.add(halfCode)
  val halfMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "half", "(I)D", halfAttrs)

  // ── double_(I)D ──────────────────────────────────────────────────────────────
  // slot 0 = n (int)
  // iload_0; i2f; fconst_2; fmul; f2d; dreturn
  val asmDbl = newAssembler(pool)
  emitIload(asmDbl, 0)
  emitI2f(asmDbl)
  emitFconst2(asmDbl)
  emitFmul(asmDbl)
  emitF2d(asmDbl)
  emitDreturn(asmDbl)
  val dblCode = assembleCode(asmDbl, 2, 1)
  val dblAttrs: List[Attribute] = newList()
  dblAttrs.add(dblCode)
  val dblMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "double_", "(I)D", dblAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(halfMethod)
  methods.add(dblMethod)
  val cf = makeClassWithMethods("FloatMath", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val halfRef = poolMethodref(pool, "FloatMath", "half", "(I)D")
  val dblRef = poolMethodref(pool, "FloatMath", "double_", "(I)D")
  val printlnD = poolMethodref(pool, "java/io/PrintStream", "println", "(D)V")

  // System.out.println(FloatMath.half(5))   → 2.5
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, halfRef)
  emitInvokevirtual(asm, printlnD)

  // System.out.println(FloatMath.double_(3)) → 6.0
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, dblRef)
  emitInvokevirtual(asm, printlnD)

  emitReturn(asm)

  // maxStack=3: getstatic(1) + double return value(2) = 3 slots
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
  val outDir = "/tmp/lyric-jvm-b46"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val floatMathBytes = makeFloatMathClassBytes()
  val mainBytes = makeMainClassBytes()

  val floatMathClass = BuiltClass(binaryName = "FloatMath", bytes = floatMathBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(floatMathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB46",
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
