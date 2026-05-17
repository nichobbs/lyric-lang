// jvm/self_test_b62.l — Stage B62: integer bitwise operations.
//
// Generates Bits.class with static methods:
//   band(II)I  — a & b   (iand)
//   bor(II)I   — a | b   (ior)
//   bxor(II)I  — a ^ b   (ixor)
//   shl(II)I   — a << b  (ishl)
//   shr(II)I   — a >> b  (ishr)
//
// Main prints:
//   band(0xFF, 0x0F) → 15
//   bor(0xF0, 0x0F)  → 255
//   bxor(0xFF, 0xA5) → 90
//   shl(1, 4)        → 16
//   shr(256, 3)      → 32
//
// Exercises: iand, ior, ixor, ishl, ishr.

package Jvm.SelfTestB62

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBitsBytes(): List[Byte] {
  val pool = poolNew()

  // band(II)I
  val asmAnd = newAssembler(pool)
  emitIload(asmAnd, 0)
  emitIload(asmAnd, 1)
  emitIand(asmAnd)
  emitIreturn(asmAnd)
  val andCode = assembleCode(asmAnd, 2, 2)
  val andAttrs: List[Attribute] = newList()
  andAttrs.add(andCode)
  val andMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "band", "(II)I", andAttrs)

  // bor(II)I
  val asmOr = newAssembler(pool)
  emitIload(asmOr, 0)
  emitIload(asmOr, 1)
  emitIor(asmOr)
  emitIreturn(asmOr)
  val orCode = assembleCode(asmOr, 2, 2)
  val orAttrs: List[Attribute] = newList()
  orAttrs.add(orCode)
  val orMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "bor", "(II)I", orAttrs)

  // bxor(II)I
  val asmXor = newAssembler(pool)
  emitIload(asmXor, 0)
  emitIload(asmXor, 1)
  emitIxor(asmXor)
  emitIreturn(asmXor)
  val xorCode = assembleCode(asmXor, 2, 2)
  val xorAttrs: List[Attribute] = newList()
  xorAttrs.add(xorCode)
  val xorMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "bxor", "(II)I", xorAttrs)

  // shl(II)I
  val asmShl = newAssembler(pool)
  emitIload(asmShl, 0)
  emitIload(asmShl, 1)
  emitIshl(asmShl)
  emitIreturn(asmShl)
  val shlCode = assembleCode(asmShl, 2, 2)
  val shlAttrs: List[Attribute] = newList()
  shlAttrs.add(shlCode)
  val shlMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "shl", "(II)I", shlAttrs)

  // shr(II)I
  val asmShr = newAssembler(pool)
  emitIload(asmShr, 0)
  emitIload(asmShr, 1)
  emitIshr(asmShr)
  emitIreturn(asmShr)
  val shrCode = assembleCode(asmShr, 2, 2)
  val shrAttrs: List[Attribute] = newList()
  shrAttrs.add(shrCode)
  val shrMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "shr", "(II)I", shrAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(andMethod)
  methods.add(orMethod)
  methods.add(xorMethod)
  methods.add(shlMethod)
  methods.add(shrMethod)
  val cf = makeClassWithMethods("Bits", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool     = poolNew()
  val asm      = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val andRef   = poolMethodref(pool, "Bits", "band", "(II)I")
  val orRef    = poolMethodref(pool, "Bits", "bor",  "(II)I")
  val xorRef   = poolMethodref(pool, "Bits", "bxor", "(II)I")
  val shlRef   = poolMethodref(pool, "Bits", "shl",  "(II)I")
  val shrRef   = poolMethodref(pool, "Bits", "shr",  "(II)I")

  // println(Bits.band(0xFF, 0x0F)) → 15
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 255)
  emitPushInt(asm, 15)
  emitInvokestatic(asm, andRef)
  emitInvokevirtual(asm, printlnI)

  // println(Bits.bor(0xF0, 0x0F))  → 255
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 240)
  emitPushInt(asm, 15)
  emitInvokestatic(asm, orRef)
  emitInvokevirtual(asm, printlnI)

  // println(Bits.bxor(0xFF, 0xA5)) → 90
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 255)
  emitPushInt(asm, 165)
  emitInvokestatic(asm, xorRef)
  emitInvokevirtual(asm, printlnI)

  // println(Bits.shl(1, 4))        → 16
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 1)
  emitPushInt(asm, 4)
  emitInvokestatic(asm, shlRef)
  emitInvokevirtual(asm, printlnI)

  // println(Bits.shr(256, 3))      → 32
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 256)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, shrRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+push(2)+push(3) = 3 peak
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
  val outDir = "/tmp/lyric-jvm-b62"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val bitsBytes = makeBitsBytes()
  val mainBytes = makeMainClassBytes()

  val bitsClass = BuiltClass(binaryName = "Bits", bytes = bitsBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(bitsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB62",
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
