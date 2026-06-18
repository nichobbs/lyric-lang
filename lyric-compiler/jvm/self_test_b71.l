// jvm/self_test_b71.l — Stage B71: java.util.TreeMap (sorted map).
//
// Generates TreeDemo.class with:
//   buildMap()TreeMap     — creates TreeMap, puts ("b","two"),("a","one"),("c","three")
//   firstKey(TreeMap)String — calls map.firstKey()
//   lastKey(TreeMap)String  — calls map.lastKey()
//   getVal(TreeMap,String)String — calls map.get(key), checkcast String
//
// Main prints:
//   firstKey → "a"      (TreeMap maintains sorted order)
//   lastKey  → "c"
//   get("b") → "two"
//
// Exercises: new java/util/TreeMap, invokevirtual TreeMap.put/firstKey/lastKey/get,
//            checkcast for Object returns, sorted-map key ordering.

package Jvm.SelfTestB71

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeTreeDemoBytes(): List[Byte] {
  val pool         = poolNew()
  val tmClass      = poolClass(pool, "java/util/TreeMap")
  val tmInit       = poolMethodref(pool, "java/util/TreeMap", "<init>",    "()V")
  val putRef       = poolMethodref(pool, "java/util/TreeMap", "put",       "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")
  val firstKeyRef  = poolMethodref(pool, "java/util/TreeMap", "firstKey",  "()Ljava/lang/Object;")
  val lastKeyRef   = poolMethodref(pool, "java/util/TreeMap", "lastKey",   "()Ljava/lang/Object;")
  val getRef       = poolMethodref(pool, "java/util/TreeMap", "get",       "(Ljava/lang/Object;)Ljava/lang/Object;")
  val strClass     = poolClass(pool, "java/lang/String")

  // buildMap()TreeMap
  val asmBuild = newAssembler(pool)
  emitNew(asmBuild, tmClass)
  emitDup(asmBuild)
  emitInvokespecial(asmBuild, tmInit)
  emitAstore(asmBuild, 0)
  // put("b","two")
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "b")
  emitPushString(asmBuild, "two")
  emitInvokevirtual(asmBuild, putRef)
  emitPop(asmBuild)
  // put("a","one")
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "a")
  emitPushString(asmBuild, "one")
  emitInvokevirtual(asmBuild, putRef)
  emitPop(asmBuild)
  // put("c","three")
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "c")
  emitPushString(asmBuild, "three")
  emitInvokevirtual(asmBuild, putRef)
  emitPop(asmBuild)
  emitAload(asmBuild, 0)
  emitAreturn(asmBuild)
  // maxStack: new(1)+dup(2) for constructor; aload(1)+str(2)+str(3) for put
  val buildCode = assembleCode(asmBuild, 3, 1)
  val buildAttrs: List[Attribute] = newList()
  buildAttrs.add(buildCode)
  val buildMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "buildMap",
    "()Ljava/util/TreeMap;", buildAttrs)

  // firstKey(TreeMap)String
  val asmFirst = newAssembler(pool)
  emitAload(asmFirst, 0)
  emitInvokevirtual(asmFirst, firstKeyRef)
  emitCheckcast(asmFirst, strClass)
  emitAreturn(asmFirst)
  val firstCode = assembleCode(asmFirst, 1, 1)
  val firstAttrs: List[Attribute] = newList()
  firstAttrs.add(firstCode)
  val firstMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "firstKey",
    "(Ljava/util/TreeMap;)Ljava/lang/String;", firstAttrs)

  // lastKey(TreeMap)String
  val asmLast = newAssembler(pool)
  emitAload(asmLast, 0)
  emitInvokevirtual(asmLast, lastKeyRef)
  emitCheckcast(asmLast, strClass)
  emitAreturn(asmLast)
  val lastCode = assembleCode(asmLast, 1, 1)
  val lastAttrs: List[Attribute] = newList()
  lastAttrs.add(lastCode)
  val lastMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "lastKey",
    "(Ljava/util/TreeMap;)Ljava/lang/String;", lastAttrs)

  // getVal(TreeMap,String)String
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitAload(asmGet, 1)
  emitInvokevirtual(asmGet, getRef)
  emitCheckcast(asmGet, strClass)
  emitAreturn(asmGet)
  val getCode = assembleCode(asmGet, 2, 2)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getVal",
    "(Ljava/util/TreeMap;Ljava/lang/String;)Ljava/lang/String;", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(buildMethod)
  methods.add(firstMethod)
  methods.add(lastMethod)
  methods.add(getMethod)
  val cf = makeClassWithMethods("TreeDemo", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool       = poolNew()
  val asm        = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS   = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val buildRef   = poolMethodref(pool, "TreeDemo", "buildMap",  "()Ljava/util/TreeMap;")
  val firstRef   = poolMethodref(pool, "TreeDemo", "firstKey",  "(Ljava/util/TreeMap;)Ljava/lang/String;")
  val lastRef    = poolMethodref(pool, "TreeDemo", "lastKey",   "(Ljava/util/TreeMap;)Ljava/lang/String;")
  val getRef     = poolMethodref(pool, "TreeDemo", "getVal",    "(Ljava/util/TreeMap;Ljava/lang/String;)Ljava/lang/String;")

  emitInvokestatic(asm, buildRef)
  emitAstore(asm, 0)

  // println(TreeDemo.firstKey(m)) → "a"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, firstRef)
  emitInvokevirtual(asm, printlnS)

  // println(TreeDemo.lastKey(m)) → "c"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, lastRef)
  emitInvokevirtual(asm, printlnS)

  // println(TreeDemo.getVal(m, "b")) → "two"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitPushString(asm, "b")
  emitInvokestatic(asm, getRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  // maxStack: getstatic(1)+aload(2)+pushStr(3) = 3 peak for getVal
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
  val outDir = "/tmp/lyric-jvm-b71"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val treeDemoBytes = makeTreeDemoBytes()
  val mainBytes     = makeMainClassBytes()

  val treeDemoClass = BuiltClass(binaryName = "TreeDemo", bytes = treeDemoBytes)
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(treeDemoClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB71",
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
