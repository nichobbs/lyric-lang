// jvm/self_test_b31.l — Stage B31: bitwise integer ops (iand, ior, ixor, irem).
//
// Generates BitOps.class with static helpers:
//   andMask(I,I)I : iand  — bitwise AND
//   orFlags(I,I)I : ior   — bitwise OR
//   xorBits(I,I)I : ixor  — bitwise XOR
//   rem(I,I)I     : irem  — integer remainder
//
// Main prints:
//   andMask(0xFF, 0x0F) = 15
//   orFlags(0xA0, 0x0B) = 171   (0xAB)
//   xorBits(10, 12)     = 6     (0b1010 ^ 0b1100 = 0b0110)
//   rem(17, 5)          = 2

package Jvm.SelfTestB31

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBitOpsClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── andMask(I,I)I ─────────────────────────────────────────────────────────
  val asmAnd = newAssembler(pool)
  emitIload(asmAnd, 0)
  emitIload(asmAnd, 1)
  emitIand(asmAnd)
  emitIreturn(asmAnd)
  val andCode = assembleCode(asmAnd, 2, 2)
  val andAttrs: List[Attribute] = newList()
  andAttrs.add(andCode)
  val andMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "andMask", "(II)I", andAttrs)

  // ── orFlags(I,I)I ─────────────────────────────────────────────────────────
  val asmOr = newAssembler(pool)
  emitIload(asmOr, 0)
  emitIload(asmOr, 1)
  emitIor(asmOr)
  emitIreturn(asmOr)
  val orCode = assembleCode(asmOr, 2, 2)
  val orAttrs: List[Attribute] = newList()
  orAttrs.add(orCode)
  val orMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "orFlags", "(II)I", orAttrs)

  // ── xorBits(I,I)I ─────────────────────────────────────────────────────────
  val asmXor = newAssembler(pool)
  emitIload(asmXor, 0)
  emitIload(asmXor, 1)
  emitIxor(asmXor)
  emitIreturn(asmXor)
  val xorCode = assembleCode(asmXor, 2, 2)
  val xorAttrs: List[Attribute] = newList()
  xorAttrs.add(xorCode)
  val xorMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "xorBits", "(II)I", xorAttrs)

  // ── rem(I,I)I ─────────────────────────────────────────────────────────────
  val asmRem = newAssembler(pool)
  emitIload(asmRem, 0)
  emitIload(asmRem, 1)
  emitIrem(asmRem)
  emitIreturn(asmRem)
  val remCode = assembleCode(asmRem, 2, 2)
  val remAttrs: List[Attribute] = newList()
  remAttrs.add(remCode)
  val remMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "rem", "(II)I", remAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(andMethod)
  methods.add(orMethod)
  methods.add(xorMethod)
  methods.add(remMethod)
  val cf = makeClassWithMethods("BitOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val andRef    = poolMethodref(pool, "BitOps", "andMask", "(II)I")
  val orRef     = poolMethodref(pool, "BitOps", "orFlags", "(II)I")
  val xorRef    = poolMethodref(pool, "BitOps", "xorBits", "(II)I")
  val remRef    = poolMethodref(pool, "BitOps", "rem",     "(II)I")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // andMask(0xFF, 0x0F) = 15
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 255)
  emitPushInt(asm, 15)
  emitInvokestatic(asm, andRef)
  emitInvokevirtual(asm, printlnI)

  // orFlags(0xA0, 0x0B) = 171
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 160)
  emitPushInt(asm, 11)
  emitInvokestatic(asm, orRef)
  emitInvokevirtual(asm, printlnI)

  // xorBits(10, 12) = 6
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitPushInt(asm, 12)
  emitInvokestatic(asm, xorRef)
  emitInvokevirtual(asm, printlnI)

  // rem(17, 5) = 2
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 17)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, remRef)
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
  val outDir = "/tmp/lyric-jvm-b31"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val bitOpsBytes = makeBitOpsClassBytes()
  val mainBytes   = makeMainClassBytes()

  val bitOpsClass = BuiltClass(binaryName = "BitOps", bytes = bitOpsBytes)
  val mainClass   = BuiltClass(binaryName = "Main",   bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(bitOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB31",
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
