// jvm/self_test_b51.l — Stage B51: java.util.HashMap (put, get, containsKey).
//
// Generates MapDemo.class with a static buildMap()Ljava/util/HashMap; that:
//   1. Creates new HashMap()
//   2. Puts ("name", "Alice") and ("score", "100")
//   3. Returns the map
//
// Main:
//   Creates the map, gets "name" and "score", prints both;
//   checks containsKey("name") → true (1), containsKey("age") → false (0).
//
// Expected output:
//   Alice
//   100
//   true
//   false
//
// Exercises: HashMap constructor, put(Object,Object)Object, get(Object)Object,
//            containsKey(Object)Z.

package Jvm.SelfTestB51

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMapDemoClassBytes(): List[Byte] {
  val pool = poolNew()

  val hashMapClass = poolClass(pool, "java/util/HashMap")
  val hashMapInit  = poolMethodref(pool, "java/util/HashMap", "<init>", "()V")
  val hashMapPut   = poolMethodref(pool, "java/util/HashMap", "put",    "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")
  val hashMapGet   = poolMethodref(pool, "java/util/HashMap", "get",    "(Ljava/lang/Object;)Ljava/lang/Object;")
  val hashMapContains = poolMethodref(pool, "java/util/HashMap", "containsKey", "(Ljava/lang/Object;)Z")
  val stringClass  = poolClass(pool, "java/lang/String")

  // ── buildMap()Ljava/util/HashMap; ────────────────────────────────────────────
  val asmBuild = newAssembler(pool)
  emitNew(asmBuild, hashMapClass)
  emitDup(asmBuild)
  emitInvokespecial(asmBuild, hashMapInit)
  emitAstore(asmBuild, 0)

  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "name")
  emitPushString(asmBuild, "Alice")
  emitInvokevirtual(asmBuild, hashMapPut)
  emitPop(asmBuild)

  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "score")
  emitPushString(asmBuild, "100")
  emitInvokevirtual(asmBuild, hashMapPut)
  emitPop(asmBuild)

  emitAload(asmBuild, 0)
  emitAreturn(asmBuild)

  // maxStack: new+dup(2), or aload+key+value(3) for put → 3
  val buildCode = assembleCode(asmBuild, 3, 1)
  val buildAttrs: List[Attribute] = newList()
  buildAttrs.add(buildCode)
  val buildMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC, "buildMap", "()Ljava/util/HashMap;", buildAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(buildMethod)
  val cf = makeClassWithMethods("MapDemo", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut      = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val printlnBool = poolMethodref(pool, "java/io/PrintStream", "println", "(Z)V")
  val buildRef    = poolMethodref(pool, "MapDemo", "buildMap", "()Ljava/util/HashMap;")
  val hashMapGet  = poolMethodref(pool, "java/util/HashMap", "get", "(Ljava/lang/Object;)Ljava/lang/Object;")
  val hashMapContains = poolMethodref(pool, "java/util/HashMap", "containsKey", "(Ljava/lang/Object;)Z")
  val stringClass = poolClass(pool, "java/lang/String")

  // val map = MapDemo.buildMap()  → local 1
  emitInvokestatic(asm, buildRef)
  emitAstore(asm, 1)

  // println((String) map.get("name"))   → "Alice"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitPushString(asm, "name")
  emitInvokevirtual(asm, hashMapGet)
  emitCheckcast(asm, stringClass)
  emitInvokevirtual(asm, printlnStr)

  // println((String) map.get("score"))  → "100"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitPushString(asm, "score")
  emitInvokevirtual(asm, hashMapGet)
  emitCheckcast(asm, stringClass)
  emitInvokevirtual(asm, printlnStr)

  // println(map.containsKey("name"))    → true
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitPushString(asm, "name")
  emitInvokevirtual(asm, hashMapContains)
  emitInvokevirtual(asm, printlnBool)

  // println(map.containsKey("age"))     → false
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitPushString(asm, "age")
  emitInvokevirtual(asm, hashMapContains)
  emitInvokevirtual(asm, printlnBool)

  emitReturn(asm)

  // maxStack: getstatic(1) + aload(2) + key(3) → get(2) → checkcast(2), max=3
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
  val outDir = "/tmp/lyric-jvm-b51"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val mapDemoBytes = makeMapDemoClassBytes()
  val mainBytes    = makeMainClassBytes()

  val mapDemoClass = BuiltClass(binaryName = "MapDemo", bytes = mapDemoBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mapDemoClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB51",
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
