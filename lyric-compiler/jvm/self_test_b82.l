// jvm/self_test_b82.l — Stage B82: multiple exception handlers (two catch clauses).
//
// Generates TryCatch.class with:
//   tryBoth(String s, int b)int
//     — try { Integer.parseInt(s) / b }
//       catch NumberFormatException { -1 }
//       catch ArithmeticException   { -2 }
//
// Main prints:
//   nfe=-1      (tryBoth("abc", 2))
//   div=-2      (tryBoth("10", 0))
//   ok=5        (tryBoth("10", 2))
//
// Exercises: exception_table with 2 entries, athrow not needed (JVM dispatches
// automatically), assembleCodeWithExHandlers, ExHandlerSpec.

package Jvm.SelfTestB82

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeTryCatchBytes(): List[Byte] {
  val pool = poolNew()

  val parseIntRef = poolMethodref(pool, "java/lang/Integer", "parseInt", "(Ljava/lang/String;)I")
  val nfeClass    = poolClass(pool, "java/lang/NumberFormatException")
  val aeClass     = poolClass(pool, "java/lang/ArithmeticException")

  // tryBoth(String s, int b)int  — slot 0=s, slot 1=b
  val asm = newAssembler(pool)
  emitLabel(asm, "TRY_START")
  emitAload(asm, 0)
  emitInvokestatic(asm, parseIntRef)
  emitIload(asm, 1)
  emitIdiv(asm)
  emitIreturn(asm)
  emitLabel(asm, "TRY_END")
  // catch NumberFormatException → return -1
  emitLabel(asm, "CATCH_NFE")
  emitPop(asm)
  emitPushInt(asm, -1)
  emitIreturn(asm)
  // catch ArithmeticException → return -2
  emitLabel(asm, "CATCH_AE")
  emitPop(asm)
  emitPushInt(asm, -2)
  emitIreturn(asm)

  val codeAttr = assembleCodeWith2Handlers(asm, 2, 2,
    "TRY_START", "TRY_END", "CATCH_NFE", nfeClass,
    "TRY_START", "TRY_END", "CATCH_AE",  aeClass
  )
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "tryBoth", "(Ljava/lang/String;I)I", attrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)
  val cf = makeClassWithMethodsV49("TryCatch", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfI  = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val tryRef    = poolMethodref(pool, "TryCatch", "tryBoth", "(Ljava/lang/String;I)I")

  // println("nfe=" + tryBoth("abc", 2))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "nfe=")
  emitPushString(asm, "abc")
  emitPushInt(asm, 2)
  emitInvokestatic(asm, tryRef)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("div=" + tryBoth("10", 0))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "div=")
  emitPushString(asm, "10")
  emitIconst(asm, 0)
  emitInvokestatic(asm, tryRef)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("ok=" + tryBoth("10", 2))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "ok=")
  emitPushString(asm, "10")
  emitPushInt(asm, 2)
  emitInvokestatic(asm, tryRef)
  emitInvokestatic(asm, valueOfI)
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
  val outDir = "/tmp/lyric-jvm-b82"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val tryCatchBytes = makeTryCatchBytes()
  val mainBytes     = makeMainClassBytes()

  val tryCatchClass = BuiltClass(binaryName = "TryCatch", bytes = tryCatchBytes)
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(tryCatchClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB82",
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
