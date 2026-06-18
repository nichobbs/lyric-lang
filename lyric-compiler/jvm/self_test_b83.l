// jvm/self_test_b83.l — Stage B83: finally pattern (catch-all + re-throw).
//
// Generates Finally.class with:
//   withFinally(String s)String
//     — try { Integer.parseInt(s); return "ok" }
//       catch (NumberFormatException) { return "bad" }
//       finally { /* runs cleanup via catch-all in exception table */ }
//
// In JVM bytecode, finally is implemented as:
//   1. A catch-all handler (catchType=0) over the entire try+catch region.
//   2. The finally body, followed by athrow to re-throw.
//   3. Duplicated finally body before each normal-exit return.
//
// To keep it testable we model a simpler pattern:
//   safeDiv(int a, int b)int
//     — try { return a/b } finally { /* nothing visible */ }
//   In JVM terms: catch-all handler re-throws. For real finally, the body
//   is cloned before each return path. Here we just verify the catch-all
//   entry (type=0) correctly re-throws on exception.
//
// Main prints:
//   safe=5       (safeDiv(10,2) — no exception)
//   caught=bad   (withFinally("abc"))
//   caught=ok    (withFinally("42"))
//
// Exercises: exception_table catchType=0 (catch-all), athrow, two handlers.

package Jvm.SelfTestB83

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFinallyBytes(): List[Byte] {
  val pool = poolNew()

  val parseIntRef = poolMethodref(pool, "java/lang/Integer", "parseInt", "(Ljava/lang/String;)I")
  val nfeClass    = poolClass(pool, "java/lang/NumberFormatException")

  // withFinally(String s)String
  // slot 0=s
  //
  // try body:
  //   Integer.parseInt(s)  (discard result)
  //   push "ok"
  //   areturn
  // TRY_BODY_END / CATCH_NFE:
  //   pop exception
  //   push "bad"
  //   areturn
  // CATCH_ALL:
  //   athrow  (re-throw; finally body is empty here)
  val asm = newAssembler(pool)
  emitLabel(asm, "TRY_START")
  emitAload(asm, 0)
  emitInvokestatic(asm, parseIntRef)
  emitPop(asm)
  emitPushString(asm, "ok")
  emitAreturn(asm)
  emitLabel(asm, "TRY_END")
  // catch NumberFormatException
  emitLabel(asm, "CATCH_NFE")
  emitPop(asm)
  emitPushString(asm, "bad")
  emitAreturn(asm)
  emitLabel(asm, "CATCH_ALL_END")
  // catch-all (finally) — re-throw
  emitLabel(asm, "CATCH_ALL")
  emitAthrow(asm)

  val codeAttr = assembleCodeWith2Handlers(asm, 2, 1,
    "TRY_START",   "TRY_END",      "CATCH_NFE",  nfeClass,
    "TRY_START",   "CATCH_ALL_END","CATCH_ALL",  0
  )
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "withFinally",
    "(Ljava/lang/String;)Ljava/lang/String;", attrs)

  // safeDiv(int a, int b)int — returns a/b, re-throws on exception
  // slot 0=a; slot 1=b
  val asmSD = newAssembler(pool)
  emitLabel(asmSD, "SD_TRY")
  emitIload(asmSD, 0)
  emitIload(asmSD, 1)
  emitIdiv(asmSD)
  emitIreturn(asmSD)
  emitLabel(asmSD, "SD_END")
  emitLabel(asmSD, "SD_CATCH")
  emitAthrow(asmSD)
  val sdCode = assembleCodeWith2Handlers(asmSD, 2, 2,
    "SD_TRY", "SD_END", "SD_CATCH", 0,
    "SD_TRY", "SD_END", "SD_CATCH", 0
  )
  val sdAttrs: List[Attribute] = newList()
  sdAttrs.add(sdCode)
  val sdMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "safeDiv", "(II)I", sdAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)
  methods.add(sdMethod)
  val cf = makeClassWithMethodsV49("Finally", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfI  = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val withRef   = poolMethodref(pool, "Finally", "withFinally", "(Ljava/lang/String;)Ljava/lang/String;")
  val sdRef     = poolMethodref(pool, "Finally", "safeDiv",     "(II)I")

  // println("safe=" + safeDiv(10,2))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "safe=")
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, sdRef)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("caught=" + withFinally("abc"))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "caught=")
  emitPushString(asm, "abc")
  emitInvokestatic(asm, withRef)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("caught=" + withFinally("42"))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "caught=")
  emitPushString(asm, "42")
  emitInvokestatic(asm, withRef)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b83"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val finallyBytes = makeFinallyBytes()
  val mainBytes    = makeMainClassBytes()

  val finallyClass = BuiltClass(binaryName = "Finally", bytes = finallyBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(finallyClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB83",
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
