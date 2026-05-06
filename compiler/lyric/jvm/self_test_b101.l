// jvm/self_test_b101.l — Stage B101: boxing/unboxing convenience insns.
//
// Adds LBoxInt/LBoxLong/LBoxFloat/LBoxDouble/LBoxBool/LBoxByte/LBoxChar/LBoxShort
// and LUnboxInt/LUnboxLong/LUnboxFloat/LUnboxDouble/LUnboxBool/LUnboxByte/
// LUnboxChar/LUnboxShort to LInsn.  Each expands to the appropriate
// invokestatic <Wrapper>.valueOf(...) or invokevirtual <Wrapper>.<prim>Value().
//
// Creates a Wrap class with static methods that demonstrate the boxing round-trip.
// Also demonstrates using a boxed value as Object (needed for generics/varargs).
//
// Java output (java -jar):
//   boxed_int=42
//   boxed_long=100
//   boxed_bool=true

package Jvm.SelfTestB101

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeRoundTripIntMethod(): LFunc {
  // roundTripInt(int n): int
  //   slot 0 = n
  //   slot 1 = boxed (Integer)
  // boxes n to Integer, stores, loads, unboxes to int, returns
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LBoxInt)                                          // Integer.valueOf(n)
  insns.add(LAstoreAs(slot = 1, className = "java/lang/Integer"))
  insns.add(LAload(slot = 1))
  insns.add(LUnboxInt)                                        // .intValue()
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "roundTripInt",
    params    = params,
    ret       = JInt,
    insns     = insns,
    maxStack  = 1,
    maxLocals = 2
  )
}

func makeRoundTripLongMethod(): LFunc {
  // roundTripLong(long n): long
  //   slot 0+1 = n
  //   slot 2+3 = boxed (Long)
  val insns: List[LInsn] = newList()
  insns.add(LLload(slot = 0))
  insns.add(LBoxLong)
  insns.add(LAstoreAs(slot = 2, className = "java/lang/Long"))
  insns.add(LAload(slot = 2))
  insns.add(LUnboxLong)
  insns.add(LLreturn)

  val params: List[JvmType] = newList()
  params.add(JLong)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "roundTripLong",
    params    = params,
    ret       = JLong,
    insns     = insns,
    maxStack  = 2,
    maxLocals = 4
  )
}

func makeRoundTripBoolMethod(): LFunc {
  // roundTripBool(boolean b): boolean
  //   slot 0 = b
  //   slot 1 = boxed (Boolean)
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LBoxBool)
  insns.add(LAstoreAs(slot = 1, className = "java/lang/Boolean"))
  insns.add(LAload(slot = 1))
  insns.add(LUnboxBool)
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JBoolean)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "roundTripBool",
    params    = params,
    ret       = JBoolean,
    insns     = insns,
    maxStack  = 1,
    maxLocals = 2
  )
}

func makeWrapBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(makeRoundTripIntMethod(), pool))
  methods.add(lowerFunc(makeRoundTripLongMethod(), pool))
  methods.add(lowerFunc(makeRoundTripBoolMethod(), pool))
  val cf = makeClassWithMethods("Wrap", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",          "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println",      "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",       "(Ljava/lang/String;)Ljava/lang/String;")
  val valOfIIdx  = poolMethodref(pool, "java/lang/String",    "valueOf",      "(I)Ljava/lang/String;")
  val valOfJIdx  = poolMethodref(pool, "java/lang/String",    "valueOf",      "(J)Ljava/lang/String;")
  val valOfBIdx  = poolMethodref(pool, "java/lang/String",    "valueOf",      "(Z)Ljava/lang/String;")
  val rtIntIdx   = poolMethodref(pool, "Wrap",                "roundTripInt",  "(I)I")
  val rtLongIdx  = poolMethodref(pool, "Wrap",                "roundTripLong", "(J)J")
  val rtBoolIdx  = poolMethodref(pool, "Wrap",                "roundTripBool", "(Z)Z")

  // println("boxed_int=" + String.valueOf(Wrap.roundTripInt(42)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "boxed_int=")
  emitPushInt(asm, 42)
  emitInvokestatic(asm, rtIntIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("boxed_long=" + String.valueOf(Wrap.roundTripLong(100L)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "boxed_long=")
  emitPushLong(asm, 100i64)
  emitInvokestatic(asm, rtLongIdx)
  emitInvokestatic(asm, valOfJIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("boxed_bool=" + String.valueOf(Wrap.roundTripBool(true)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "boxed_bool=")
  emitPushInt(asm, 1)                  // true = iconst_1
  emitInvokestatic(asm, rtBoolIdx)
  emitInvokestatic(asm, valOfBIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b101"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val wrapClass  = BuiltClass(binaryName = "Wrap", bytes = makeWrapBytes())
  val mainClass  = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(wrapClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB101",
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
