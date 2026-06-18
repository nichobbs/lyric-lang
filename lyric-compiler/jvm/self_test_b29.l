//! jvm/self_test_b29.l — Stage B29: instanceof + checkcast.
//!
//! Generates TypeCheck.class with two static helpers:
//!   isString(Ljava/lang/Object;)Z  — returns 1 if arg is a String instance
//!   castToString(Ljava/lang/Object;)Ljava/lang/String; — casts arg to String
//!
//! Main:
//!   println(TypeCheck.isString("hello"))   → 1 (true)
//!   println(TypeCheck.castToString("world")) → "world"
//!
//! Exercises: emitInstanceof, emitCheckcast, invoking with Object supertype.
package Jvm.SelfTestB29

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeTypeCheckClassBytes(): List[Byte] {
  val pool = poolNew()

  val strClass = poolClass(pool, "java/lang/String")

  // ── isString(Ljava/lang/Object;)Z ────────────────────────────────────────
  val asmIS = newAssembler(pool)
  emitAload(asmIS, 0)
  emitInstanceof(asmIS, strClass)
  emitIreturn(asmIS)
  val isCode = assembleCode(asmIS, 1, 1)
  val isAttrs: List[Attribute] = newList()
  isAttrs.add(isCode)
  val isStringMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "isString", "(Ljava/lang/Object;)Z", isAttrs)

  // ── castToString(Ljava/lang/Object;)Ljava/lang/String; ────────────────────
  val asmCS = newAssembler(pool)
  emitAload(asmCS, 0)
  emitCheckcast(asmCS, strClass)
  emitAreturn(asmCS)
  val csCode = assembleCode(asmCS, 1, 1)
  val csAttrs: List[Attribute] = newList()
  csAttrs.add(csCode)
  val castToStringMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "castToString",
    "(Ljava/lang/Object;)Ljava/lang/String;",
    csAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(isStringMethod)
  methods.add(castToStringMethod)
  val cf = makeClassWithMethods("TypeCheck", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val isStringRef = poolMethodref(pool, "TypeCheck", "isString", "(Ljava/lang/Object;)Z")
  val castToStrRef = poolMethodref(pool, "TypeCheck", "castToString", "(Ljava/lang/Object;)Ljava/lang/String;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // System.out.println(TypeCheck.isString("hello"))  → prints 1
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello")
  emitInvokestatic(asm, isStringRef)
  emitInvokevirtual(asm, printlnI)

  // System.out.println(TypeCheck.castToString("world"))  → prints "world"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "world")
  emitInvokestatic(asm, castToStrRef)
  emitInvokevirtual(asm, printlnS)

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
  val outDir = "/tmp/lyric-jvm-b29"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val typeCheckBytes = makeTypeCheckClassBytes()
  val mainBytes = makeMainClassBytes()

  val typeCheckClass = BuiltClass(binaryName = "TypeCheck", bytes = typeCheckBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(typeCheckClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB29",
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
