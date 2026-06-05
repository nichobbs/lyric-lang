//! jvm/self_test_b32.l — Stage B32: shift ops (ishl, ishr, iushr) and long comparison (lcmp).
//!
//! Generates ShiftOps.class with:
//!   shl(I,I)I  : ishl  — arithmetic left shift
//!   shr(I,I)I  : ishr  — arithmetic right shift (sign-extending)
//!   ushr(I,I)I : iushr — logical right shift (zero-filling)
//!   lcmp0(J,J)I: lcmp  — compare two longs, return -1/0/1
//!
//! Main prints:
//!   shl(1, 4)      =  16
//!   shr(-8, 1)     =  -4   (sign preserved)
//!   ushr(-1, 28)   =  15   (0xFFFFFFFF >>> 28 = 0xF)
//!   lcmp0(100L, 50L) = 1   (a > b)
package Jvm.SelfTestB32

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeShiftOpsClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── shl(I,I)I ─────────────────────────────────────────────────────────────
  val asmShl = newAssembler(pool)
  emitIload(asmShl, 0)
  emitIload(asmShl, 1)
  emitIshl(asmShl)
  emitIreturn(asmShl)
  val shlCode = assembleCode(asmShl, 2, 2)
  val shlAttrs: List[Attribute] = newList()
  shlAttrs.add(shlCode)
  val shlMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "shl", "(II)I", shlAttrs)

  // ── shr(I,I)I ─────────────────────────────────────────────────────────────
  val asmShr = newAssembler(pool)
  emitIload(asmShr, 0)
  emitIload(asmShr, 1)
  emitIshr(asmShr)
  emitIreturn(asmShr)
  val shrCode = assembleCode(asmShr, 2, 2)
  val shrAttrs: List[Attribute] = newList()
  shrAttrs.add(shrCode)
  val shrMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "shr", "(II)I", shrAttrs)

  // ── ushr(I,I)I ────────────────────────────────────────────────────────────
  val asmUshr = newAssembler(pool)
  emitIload(asmUshr, 0)
  emitIload(asmUshr, 1)
  emitIushr(asmUshr)
  emitIreturn(asmUshr)
  val ushrCode = assembleCode(asmUshr, 2, 2)
  val ushrAttrs: List[Attribute] = newList()
  ushrAttrs.add(ushrCode)
  val ushrMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "ushr", "(II)I", ushrAttrs)

  // ── lcmp0(J,J)I — compare two longs ──────────────────────────────────────
  // slot 0-1 = first long, slot 2-3 = second long
  val asmLcmp = newAssembler(pool)
  emitLload(asmLcmp, 0)
  emitLload(asmLcmp, 2)
  emitLcmp(asmLcmp)
  emitIreturn(asmLcmp)
  val lcmpCode = assembleCode(asmLcmp, 4, 4)
  val lcmpAttrs: List[Attribute] = newList()
  lcmpAttrs.add(lcmpCode)
  val lcmpMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "lcmp0", "(JJ)I", lcmpAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(shlMethod)
  methods.add(shrMethod)
  methods.add(ushrMethod)
  methods.add(lcmpMethod)
  val cf = makeClassWithMethods("ShiftOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val shlRef = poolMethodref(pool, "ShiftOps", "shl", "(II)I")
  val shrRef = poolMethodref(pool, "ShiftOps", "shr", "(II)I")
  val ushrRef = poolMethodref(pool, "ShiftOps", "ushr", "(II)I")
  val lcmpRef = poolMethodref(pool, "ShiftOps", "lcmp0", "(JJ)I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // shl(1, 4) = 16
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 1)
  emitPushInt(asm, 4)
  emitInvokestatic(asm, shlRef)
  emitInvokevirtual(asm, printlnI)

  // shr(-8, 1) = -4
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -8)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, shrRef)
  emitInvokevirtual(asm, printlnI)

  // ushr(-1, 28) = 15  (0xFFFFFFFF >>> 28)
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -1)
  emitPushInt(asm, 28)
  emitInvokestatic(asm, ushrRef)
  emitInvokevirtual(asm, printlnI)

  // lcmp0(100L, 50L) = 1  (100 > 50)
  emitGetstatic(asm, sysOut)
  emitPushLong(asm, 100i64)
  emitPushLong(asm, 50i64)
  emitInvokestatic(asm, lcmpRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // max_stack: getstatic + 2 longs = 1 + 4 = 5
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
  val outDir = "/tmp/lyric-jvm-b32"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val shiftOpsBytes = makeShiftOpsClassBytes()
  val mainBytes = makeMainClassBytes()

  val shiftOpsClass = BuiltClass(binaryName = "ShiftOps", bytes = shiftOpsBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(shiftOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB32",
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
