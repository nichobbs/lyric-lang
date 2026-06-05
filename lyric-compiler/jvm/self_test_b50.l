//! jvm/self_test_b50.l — Stage B50: java.util.ArrayList (add, get, size).
//!
//! Generates ListDemo.class with a static buildList()Ljava/util/ArrayList; that:
//!   1. Creates new ArrayList()
//!   2. Adds "hello" and "world"
//!   3. Returns the list
//!
//! Main:
//!   Creates the list, gets index 0 (checkcast String) and index 1, prints both,
//!   then prints size().
//!
//! Expected output:
//!   hello
//!   world
//!   2
//!
//! Exercises: ArrayList constructor, add(Object)Z, get(I)Object, size()I,
//!            checkcast for narrowing Object to String.
package Jvm.SelfTestB50

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeListDemoClassBytes(): List[Byte] {
  val pool = poolNew()

  val arrayListClass = poolClass(pool, "java/util/ArrayList")
  val arrayListInit = poolMethodref(pool, "java/util/ArrayList", "<init>", "()V")
  val arrayListAdd = poolMethodref(pool, "java/util/ArrayList", "add", "(Ljava/lang/Object;)Z")
  val arrayListGet = poolMethodref(pool, "java/util/ArrayList", "get", "(I)Ljava/lang/Object;")
  val arrayListSize = poolMethodref(pool, "java/util/ArrayList", "size", "()I")
  val stringClass = poolClass(pool, "java/lang/String")

  // ── buildList()Ljava/util/ArrayList; ─────────────────────────────────────────
  // new ArrayList(); dup; invokespecial <init>; astore_0
  // aload_0; ldc "hello"; invokevirtual add; pop
  // aload_0; ldc "world"; invokevirtual add; pop
  // aload_0; areturn
  val asmBuild = newAssembler(pool)
  emitNew(asmBuild, arrayListClass)
  emitDup(asmBuild)
  emitInvokespecial(asmBuild, arrayListInit)
  emitAstore(asmBuild, 0)

  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "hello")
  emitInvokevirtual(asmBuild, arrayListAdd)
  emitPop(asmBuild)

  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "world")
  emitInvokevirtual(asmBuild, arrayListAdd)
  emitPop(asmBuild)

  emitAload(asmBuild, 0)
  emitAreturn(asmBuild)

  // maxStack: new+dup = 2, aload+string = 2 slots, maxStack = 2
  val buildCode = assembleCode(asmBuild, 2, 1)
  val buildAttrs: List[Attribute] = newList()
  buildAttrs.add(buildCode)
  val buildMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "buildList", "()Ljava/util/ArrayList;", buildAttrs)

  val buildRef = poolMethodref(pool, "ListDemo", "buildList", "()Ljava/util/ArrayList;")

  val methods: List[MethodInfo] = newList()
  methods.add(buildMethod)
  val cf = makeClassWithMethods("ListDemo", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val buildRef = poolMethodref(pool, "ListDemo", "buildList", "()Ljava/util/ArrayList;")
  val arrayListGet = poolMethodref(pool, "java/util/ArrayList", "get", "(I)Ljava/lang/Object;")
  val arrayListSize = poolMethodref(pool, "java/util/ArrayList", "size", "()I")
  val stringClass = poolClass(pool, "java/lang/String")

  // val list = ListDemo.buildList()   → local 1
  emitInvokestatic(asm, buildRef)
  emitAstore(asm, 1)

  // println((String) list.get(0))  → "hello"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitIconst(asm, 0)
  emitInvokevirtual(asm, arrayListGet)
  emitCheckcast(asm, stringClass)
  emitInvokevirtual(asm, printlnStr)

  // println((String) list.get(1))  → "world"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitIconst(asm, 1)
  emitInvokevirtual(asm, arrayListGet)
  emitCheckcast(asm, stringClass)
  emitInvokevirtual(asm, printlnStr)

  // println(list.size())  → 2
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitInvokevirtual(asm, arrayListSize)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1) + aload(2) + iconst(3) → get(2) → checkcast(2), max=3
  val codeAttr = assembleCode(asm, 3, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b50"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val listDemoBytes = makeListDemoClassBytes()
  val mainBytes = makeMainClassBytes()

  val listDemoClass = BuiltClass(binaryName = "ListDemo", bytes = listDemoBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(listDemoClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB50",
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
