//! jvm/self_test_b98.l — Stage B98: bitwise int ops + long comparison.
//!
//! Adds LIand/LIor/LIxor/LIshl/LIshr/LIushr/LLcmp (and the missing bytecode.l
//! emit helpers) to the LInsn union and lowerInsn dispatch.
//!
//! Creates a BitOps class via lowerFunc with two static methods:
//!   countBits(int n): int  — counts set bits using n & 1 and n >>> 1
//!   sumLong(long a, long b): long — returns a + b if a < b, else a - b
//!                                   (exercises LLcmp + LIfeq branch)
//!
//! Java output (java -jar):
//!   bits(0)=0
//!   bits(7)=3
//!   bits(255)=8
//!   cmp(3,7)=10
//!   cmp(9,2)=7
package Jvm.SelfTestB98

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeCountBitsMethod(): LFunc {
  // countBits(int n): int
  //   slot 0 = n  (parameter, shifted right each iteration)
  //   slot 1 = count (accumulator)
  //
  // Result-slot pattern (B5 invariant: empty stack at branch targets):
  //   count = 0
  //   [loop]:  if n == 0 goto done
  //            count = count + (n & 1)
  //            n = n >>> 1
  //            goto loop
  //   [done]:  return count
  val insns: List[LInsn] = newList()
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = 1))
  // count = 0
  insns.add(LLabel(name = "loop"))
  // <- branch target
  insns.add(LIload(slot = 0))
  // n
  insns.add(LIfeq(label = "done"))
  // if n == 0 goto done
  insns.add(LIload(slot = 1))
  // count
  insns.add(LIload(slot = 0))
  // n
  insns.add(LIconst(v = 1))
  // 1
  insns.add(LIand)
  // n & 1
  insns.add(LIadd)
  // count + (n & 1)
  insns.add(LIstore(slot = 1))
  // count = ...
  insns.add(LIload(slot = 0))
  // n
  insns.add(LIconst(v = 1))
  // 1
  insns.add(LIushr)
  // n >>> 1
  insns.add(LIstore(slot = 0))
  // n = n >>> 1
  insns.add(LGoto(label = "loop"))
  insns.add(LLabel(name = "done"))
  // <- branch target
  insns.add(LIload(slot = 1))
  // count
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "countBits",
    params = params,
    ret = JInt,
    insns = insns,
    maxStack = 3,
    maxLocals = 2
  )
}

func makeSumLongMethod(): LFunc {
  // sumLong(long a, long b): long
  //   slot 0+1 = a (long, 2 slots)
  //   slot 2+3 = b (long, 2 slots)
  //   slot 4+5 = result (long, 2 slots)
  //
  // if a < b  (i.e. lcmp -> ifeq/ifge... actually: lcmp leaves -1/0/1,
  //   a < b => lcmp gives -1 => iflt "take_sum")
  //   result = a + b
  // else
  //   result = a - b
  // return result
  //
  // Pattern:
  //   result = a - b   (default: a >= b)
  //   lload a; lload b; lcmp; ifge skip_update
  //   result = a + b
  //   [skip_update]:
  //   return result
  val insns: List[LInsn] = newList()
  insns.add(LLload(slot = 0))
  insns.add(LLload(slot = 2))
  insns.add(LLsub)
  insns.add(LLstore(slot = 4))
  // result = a - b
  insns.add(LLload(slot = 0))
  // a
  insns.add(LLload(slot = 2))
  // b
  insns.add(LLcmp)
  // -1/0/1
  insns.add(LIfge(label = "skip"))
  // if a >= b, skip update
  insns.add(LLload(slot = 0))
  insns.add(LLload(slot = 2))
  insns.add(LLadd)
  insns.add(LLstore(slot = 4))
  // result = a + b
  insns.add(LLabel(name = "skip"))
  // <- branch target
  insns.add(LLload(slot = 4))
  insns.add(LLreturn)

  val params: List[JvmType] = newList()
  params.add(JLong)
  params.add(JLong)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "sumLong",
    params = params,
    ret = JLong,
    insns = insns,
    maxStack = 4,
    maxLocals = 6
  )
}

func makeBitOpsBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(makeCountBitsMethod(), pool))
  methods.add(lowerFunc(makeSumLongMethod(), pool))
  val cf = makeClassWithMethods("BitOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valOfIIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val valOfLIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(J)Ljava/lang/String;")
  val countBitsIdx = poolMethodref(pool, "BitOps", "countBits", "(I)I")
  val sumLongIdx = poolMethodref(pool, "BitOps", "sumLong", "(JJ)J")

  // println("bits(0)=" + String.valueOf(BitOps.countBits(0)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "bits(0)=")
  emitPushInt(asm, 0)
  emitInvokestatic(asm, countBitsIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("bits(7)=" + String.valueOf(BitOps.countBits(7)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "bits(7)=")
  emitPushInt(asm, 7)
  emitInvokestatic(asm, countBitsIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("bits(255)=" + String.valueOf(BitOps.countBits(255)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "bits(255)=")
  emitPushInt(asm, 255)
  emitInvokestatic(asm, countBitsIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("cmp(3,7)=" + String.valueOf(BitOps.sumLong(3, 7)))  => 3+7=10
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "cmp(3,7)=")
  emitPushLong(asm, 3i64)
  emitPushLong(asm, 7i64)
  emitInvokestatic(asm, sumLongIdx)
  emitInvokestatic(asm, valOfLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("cmp(9,2)=" + String.valueOf(BitOps.sumLong(9, 2)))  => 9-2=7
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "cmp(9,2)=")
  emitPushLong(asm, 9i64)
  emitPushLong(asm, 2i64)
  emitInvokestatic(asm, sumLongIdx)
  emitInvokestatic(asm, valOfLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 6, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b98"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val bitOpsClass = BuiltClass(binaryName = "BitOps", bytes = makeBitOpsBytes())
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(bitOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB98",
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
