// jvm/self_test_b55.l — Stage B55: String operations (concat, length, substring).
//
// Generates StringOps.class with static helpers:
//   join(String, String)String   — a.concat(b)
//   length(String)I              — s.length()
//   initial(String)String        — s.substring(0, 1)
//
// Main prints:
//   join("Hello, ", "World!") → "Hello, World!"
//   length("Lyric")           → 5
//   initial("Alice")          → "A"
//
// Exercises: invokevirtual String.concat, String.length, String.substring(I,I).

package Jvm.SelfTestB55

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeStringOpsClassBytes(): List[Byte] {
  val pool = poolNew()

  val strConcat    = poolMethodref(pool, "java/lang/String", "concat",    "(Ljava/lang/String;)Ljava/lang/String;")
  val strLength    = poolMethodref(pool, "java/lang/String", "length",    "()I")
  val strSubstring = poolMethodref(pool, "java/lang/String", "substring", "(II)Ljava/lang/String;")

  // ── join(String, String)String ─────────────────────────────────────────────
  // aload_0; aload_1; invokevirtual concat; areturn
  val asmJoin = newAssembler(pool)
  emitAload(asmJoin, 0)
  emitAload(asmJoin, 1)
  emitInvokevirtual(asmJoin, strConcat)
  emitAreturn(asmJoin)
  val joinCode = assembleCode(asmJoin, 2, 2)
  val joinAttrs: List[Attribute] = newList()
  joinAttrs.add(joinCode)
  val joinMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC, "join", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", joinAttrs
  )

  // ── length(String)I ───────────────────────────────────────────────────────
  // aload_0; invokevirtual length; ireturn
  val asmLen = newAssembler(pool)
  emitAload(asmLen, 0)
  emitInvokevirtual(asmLen, strLength)
  emitIreturn(asmLen)
  val lenCode = assembleCode(asmLen, 1, 1)
  val lenAttrs: List[Attribute] = newList()
  lenAttrs.add(lenCode)
  val lenMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC, "length", "(Ljava/lang/String;)I", lenAttrs
  )

  // ── initial(String)String ──────────────────────────────────────────────────
  // aload_0; iconst_0; iconst_1; invokevirtual substring(II); areturn
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitIconst(asmInit, 0)
  emitIconst(asmInit, 1)
  emitInvokevirtual(asmInit, strSubstring)
  emitAreturn(asmInit)
  val initCode = assembleCode(asmInit, 3, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC, "initial", "(Ljava/lang/String;)Ljava/lang/String;", initAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(joinMethod)
  methods.add(lenMethod)
  methods.add(initMethod)
  val cf = makeClassWithMethods("StringOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val printlnI   = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val joinRef    = poolMethodref(pool, "StringOps", "join",    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val lenRef     = poolMethodref(pool, "StringOps", "length",  "(Ljava/lang/String;)I")
  val initRef    = poolMethodref(pool, "StringOps", "initial", "(Ljava/lang/String;)Ljava/lang/String;")

  // println(StringOps.join("Hello, ", "World!"))  → "Hello, World!"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Hello, ")
  emitPushString(asm, "World!")
  emitInvokestatic(asm, joinRef)
  emitInvokevirtual(asm, printlnStr)

  // println(StringOps.length("Lyric"))  → 5
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Lyric")
  emitInvokestatic(asm, lenRef)
  emitInvokevirtual(asm, printlnI)

  // println(StringOps.initial("Alice"))  → "A"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Alice")
  emitInvokestatic(asm, initRef)
  emitInvokevirtual(asm, printlnStr)

  emitReturn(asm)

  // maxStack: getstatic(1) + str1(2) + str2(3) peak (for join call)
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
  val outDir = "/tmp/lyric-jvm-b55"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val stringOpsBytes = makeStringOpsClassBytes()
  val mainBytes      = makeMainClassBytes()

  val stringOpsClass = BuiltClass(binaryName = "StringOps", bytes = stringOpsBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(stringOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB55",
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
