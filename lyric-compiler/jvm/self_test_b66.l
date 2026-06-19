//! jvm/self_test_b66.l — Stage B66: String.valueOf for int, long, boolean.
//!
//! Generates Stringifier.class with:
//!   intToStr(I)String    — String.valueOf(i)
//!   longToStr(J)String   — String.valueOf(l)
//!   boolToStr(I)String   — String.valueOf(z != 0)  using z as int (0=false,1=true)
//!
//! Main prints:
//!   intToStr(42)         → "42"
//!   intToStr(-100)       → "-100"
//!   longToStr(999999999) → "999999999"
//!   boolToStr(1)         → "true"
//!   boolToStr(0)         → "false"
//!
//! Exercises: invokestatic String.valueOf(I), String.valueOf(J), String.valueOf(Z).
package Jvm.SelfTestB66

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeStringifierBytes(): List[Byte] {
  val pool = poolNew()
  val valueOfI = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val valueOfJ = poolMethodref(pool, "java/lang/String", "valueOf", "(J)Ljava/lang/String;")
  val valueOfZ = poolMethodref(pool, "java/lang/String", "valueOf", "(Z)Ljava/lang/String;")

  // intToStr(I)String
  val asmI = newAssembler(pool)
  emitIload(asmI, 0)
  emitInvokestatic(asmI, valueOfI)
  emitAreturn(asmI)
  val iCode = assembleCode(asmI, 1, 1)
  val iAttrs: List[Attribute] = newList()
  iAttrs.add(iCode)
  val iMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "intToStr", "(I)Ljava/lang/String;", iAttrs)

  // longToStr(J)String  — slot 0+1=l
  val asmJ = newAssembler(pool)
  emitLload(asmJ, 0)
  emitInvokestatic(asmJ, valueOfJ)
  emitAreturn(asmJ)
  val jCode = assembleCode(asmJ, 2, 2)
  val jAttrs: List[Attribute] = newList()
  jAttrs.add(jCode)
  val jMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "longToStr", "(J)Ljava/lang/String;", jAttrs)

  // boolToStr(I)String  — slot 0=z (int; 0=false, 1=true)
  val asmZ = newAssembler(pool)
  emitIload(asmZ, 0)
  emitInvokestatic(asmZ, valueOfZ)
  emitAreturn(asmZ)
  val zCode = assembleCode(asmZ, 1, 1)
  val zAttrs: List[Attribute] = newList()
  zAttrs.add(zCode)
  val zMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "boolToStr", "(I)Ljava/lang/String;", zAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(iMethod)
  methods.add(jMethod)
  methods.add(zMethod)
  val cf = makeClassWithMethods("Stringifier", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val iRef = poolMethodref(pool, "Stringifier", "intToStr", "(I)Ljava/lang/String;")
  val jRef = poolMethodref(pool, "Stringifier", "longToStr", "(J)Ljava/lang/String;")
  val zRef = poolMethodref(pool, "Stringifier", "boolToStr", "(I)Ljava/lang/String;")

  // println(Stringifier.intToStr(42))         → "42"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 42)
  emitInvokestatic(asm, iRef)
  emitInvokevirtual(asm, printlnS)

  // println(Stringifier.intToStr(-100))        → "-100"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -100)
  emitInvokestatic(asm, iRef)
  emitInvokevirtual(asm, printlnS)

  // println(Stringifier.longToStr(999999999L)) → "999999999"
  emitGetstatic(asm, sysOut)
  emitPushLong(asm, 999999999i64)
  emitInvokestatic(asm, jRef)
  emitInvokevirtual(asm, printlnS)

  // println(Stringifier.boolToStr(1))          → "true"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, zRef)
  emitInvokevirtual(asm, printlnS)

  // println(Stringifier.boolToStr(0))          → "false"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, zRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  // maxStack: getstatic(1)+pushLong(3) = 3 peak for longToStr call
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
  val outDir = "/tmp/lyric-jvm-b66"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val stringifierBytes = makeStringifierBytes()
  val mainBytes = makeMainClassBytes()

  val stringifierClass = BuiltClass(binaryName = "Stringifier", bytes = stringifierBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(stringifierClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB66",
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
