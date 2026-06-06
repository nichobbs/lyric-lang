//! jvm/self_test_b28.l — Stage B28: widening and narrowing casts (i2l, i2d, d2i, l2i).
//!
//! Generates Casts.class with static helper methods:
//!   intToLong(I)J  : i2l  — widening int → long
//!   intToDouble(I)D: i2d  — widening int → double
//!   doubleToInt(D)I: d2i  — narrowing double → int (truncates toward zero)
//!
//! Main demonstrates all three and prints:
//!   1000000000000   (100000 widened to long, squared via Jvm.SelfTestB26.LongMath is out of scope;
//!                    instead just do intToLong(42) * intToLong(42) = 1764)
//!   3.14159         (intToDouble(314159) / 100000.0)
//!   2               (doubleToInt(2.99) truncates to 2)
//!
//! Exercises: emitI2l, emitI2d, emitD2i (explicit JVM primitive casts).
package Jvm.SelfTestB28

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCastsClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── intToLong(I)J ─────────────────────────────────────────────────────────
  val asmIL = newAssembler(pool)
  emitIload(asmIL, 0)
  emitI2l(asmIL)
  emitLreturn(asmIL)
  val ilCode = assembleCode(asmIL, 2, 2)
  val ilAttrs: List[Attribute] = newList()
  ilAttrs.add(ilCode)
  val intToLongMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "intToLong", "(I)J", ilAttrs)

  // ── intToDouble(I)D ───────────────────────────────────────────────────────
  val asmID = newAssembler(pool)
  emitIload(asmID, 0)
  emitI2d(asmID)
  emitDreturn(asmID)
  val idCode = assembleCode(asmID, 2, 2)
  val idAttrs: List[Attribute] = newList()
  idAttrs.add(idCode)
  val intToDoubleMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "intToDouble", "(I)D", idAttrs)

  // ── doubleToInt(D)I ───────────────────────────────────────────────────────
  val asmDI = newAssembler(pool)
  emitDload(asmDI, 0)
  emitD2i(asmDI)
  emitIreturn(asmDI)
  val diCode = assembleCode(asmDI, 2, 2)
  val diAttrs: List[Attribute] = newList()
  diAttrs.add(diCode)
  val doubleToIntMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "doubleToInt", "(D)I", diAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(intToLongMethod)
  methods.add(intToDoubleMethod)
  methods.add(doubleToIntMethod)
  val cf = makeClassWithMethods("Casts", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val intToLongRef = poolMethodref(pool, "Casts", "intToLong", "(I)J")
  val intToDoubleRef = poolMethodref(pool, "Casts", "intToDouble", "(I)D")
  val doubleToIntRef = poolMethodref(pool, "Casts", "doubleToInt", "(D)I")
  val printlnJ = poolMethodref(pool, "java/io/PrintStream", "println", "(J)V")
  val printlnD = poolMethodref(pool, "java/io/PrintStream", "println", "(D)V")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // Print 1: intToLong(42) as long → println(J)
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 42)
  emitInvokestatic(asm, intToLongRef)
  emitInvokevirtual(asm, printlnJ)

  // Print 2: intToDouble(314159) / 100000.0 → println(D)
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 314159)
  emitInvokestatic(asm, intToDoubleRef)
  emitPushDouble(asm, 100000.0)
  emitDdiv(asm)
  emitInvokevirtual(asm, printlnD)

  // Print 3: doubleToInt(2.99) → println(I)
  emitGetstatic(asm, sysOut)
  emitPushDouble(asm, 2.99)
  emitInvokestatic(asm, doubleToIntRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // max_stack: getstatic + double + double = 5 (ps + 2 double slots + 1 double = 5)
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
  val outDir = "/tmp/lyric-jvm-b28"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val castsBytes = makeCastsClassBytes()
  val mainBytes = makeMainClassBytes()

  val castsClass = BuiltClass(binaryName = "Casts", bytes = castsBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(castsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB28",
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
