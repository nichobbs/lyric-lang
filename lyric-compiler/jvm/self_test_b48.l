//! jvm/self_test_b48.l — Stage B48: Integer boxing and unboxing.
//!
//! Generates Boxer.class with two static helpers:
//!   box(I)Ljava/lang/Integer;    — Integer.valueOf(n)
//!   unbox(Ljava/lang/Integer;)I  — intValue()
//!   roundTrip(I)I                — unbox(box(n)) = n
//!
//! Main prints:
//!   roundTrip(42)  → 42
//!   roundTrip(-7)  → -7
//!
//! Exercises: invokestatic Integer.valueOf(I), invokevirtual Integer.intValue(),
//!            areturn on boxed reference, aload of reference parameter.
package Jvm.SelfTestB48

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBoxerClassBytes(): List[Byte] {
  val pool = poolNew()

  val intValueOf = poolMethodref(pool, "java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;")
  val intValue_ = poolMethodref(pool, "java/lang/Integer", "intValue", "()I")

  // ── box(I)Ljava/lang/Integer; ─────────────────────────────────────────────────
  val asmBox = newAssembler(pool)
  emitIload(asmBox, 0)
  emitInvokestatic(asmBox, intValueOf)
  emitAreturn(asmBox)
  val boxCode = assembleCode(asmBox, 1, 1)
  val boxAttrs: List[Attribute] = newList()
  boxAttrs.add(boxCode)
  val boxMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "box", "(I)Ljava/lang/Integer;", boxAttrs)

  // ── unbox(Ljava/lang/Integer;)I ──────────────────────────────────────────────
  val asmUnbox = newAssembler(pool)
  emitAload(asmUnbox, 0)
  emitInvokevirtual(asmUnbox, intValue_)
  emitIreturn(asmUnbox)
  val unboxCode = assembleCode(asmUnbox, 1, 1)
  val unboxAttrs: List[Attribute] = newList()
  unboxAttrs.add(unboxCode)
  val unboxMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "unbox", "(Ljava/lang/Integer;)I", unboxAttrs)

  // ── roundTrip(I)I: unbox(box(n)) ─────────────────────────────────────────────
  val boxRef = poolMethodref(pool, "Boxer", "box", "(I)Ljava/lang/Integer;")
  val unboxRef = poolMethodref(pool, "Boxer", "unbox", "(Ljava/lang/Integer;)I")
  val asmRT = newAssembler(pool)
  emitIload(asmRT, 0)
  emitInvokestatic(asmRT, boxRef)
  emitInvokestatic(asmRT, unboxRef)
  emitIreturn(asmRT)
  val rtCode = assembleCode(asmRT, 1, 1)
  val rtAttrs: List[Attribute] = newList()
  rtAttrs.add(rtCode)
  val rtMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "roundTrip", "(I)I", rtAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(boxMethod)
  methods.add(unboxMethod)
  methods.add(rtMethod)
  val cf = makeClassWithMethods("Boxer", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val rtRef = poolMethodref(pool, "Boxer", "roundTrip", "(I)I")

  // println(Boxer.roundTrip(42))  → 42
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 42)
  emitInvokestatic(asm, rtRef)
  emitInvokevirtual(asm, printlnI)

  // println(Boxer.roundTrip(-7))  → -7
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -7)
  emitInvokestatic(asm, rtRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b48"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val boxerBytes = makeBoxerClassBytes()
  val mainBytes = makeMainClassBytes()

  val boxerClass = BuiltClass(binaryName = "Boxer", bytes = boxerBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(boxerClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB48",
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
