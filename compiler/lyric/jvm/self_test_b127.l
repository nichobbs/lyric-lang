// jvm/self_test_b127.l — Stage B127: Std.Jvm.catch intrinsic bytecode pattern.
//
// Validates the bytecode shape that lowerCatchIntrinsic (codegen.l) emits:
//   1. Creates a Wrapper union with Ok(value: Object) and Err(error: Object) cases.
//   2. Creates SafeDiv with static safeDivide(int a, int b): Object that wraps
//      integer division in a try-catch:
//        success         → Wrapper$Ok(Integer(result))
//        ArithmeticException → Wrapper$Err(exception)
//   3. Main calls safeDivide(10, 2) and safeDivide(10, 0) and prints the results.
//
// Java output (java -jar):
//   divide(10,2)=ok:5
//   divide(10,0)=err:ArithmeticException

package Jvm.SelfTestB127

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Wrapper union (abstract base + Ok/Err case classes) ────────────────

func makeWrapperBytes(): List[List[Byte]] {
  val pool = poolNew()

  val okFields: List[LField] = newList()
  okFields.add(LField(flags = ACC_PUBLIC, name = "value", fieldType = JRef(className = "java/lang/Object")))

  val errFields: List[LField] = newList()
  errFields.add(LField(flags = ACC_PUBLIC, name = "error", fieldType = JRef(className = "java/lang/Object")))

  val cases: List[LUnionCase] = newList()
  cases.add(LUnionCase(caseName = "Ok",  fields = okFields))
  cases.add(LUnionCase(caseName = "Err", fields = errFields))

  val baseMethods: List[LFunc] = newList()
  val u = LUnion(baseName = "Wrapper", cases = cases, methods = baseMethods)
  val classFiles = lowerUnion(u, pool)

  val result: List[List[Byte]] = newList()
  var i = 0
  while i < classFiles.count {
    result.add(serializeClassWithPool(classFiles[i], pool))
    i = i + 1
  }
  result
}

// ── Build SafeDiv class with inline try-catch ─────────────────────────────────
//
// Replicates the bytecode shape lowerCatchIntrinsic emits:
//   [try_start]: idiv; box; astore; new Wrapper$Ok; dup; aload; invokespecial
//   [try_end]:   goto [after]
//   [catch_handler]: astore; new Wrapper$Err; dup; aload; invokespecial
//   [after]:     areturn
//
// V49 (Java 5) avoids StackMapTable requirement at the catch-handler entry.

func makeSafeDivBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val integerValueOfIdx = poolMethodref(pool, "java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;")
  val okClassIdx        = poolClass(pool, "Wrapper$Ok")
  val errClassIdx       = poolClass(pool, "Wrapper$Err")
  val okCtorIdx         = poolMethodref(pool, "Wrapper$Ok",  "<init>", "(Ljava/lang/Object;)V")
  val errCtorIdx        = poolMethodref(pool, "Wrapper$Err", "<init>", "(Ljava/lang/Object;)V")
  val aeClassIdx        = poolClass(pool, "java/lang/ArithmeticException")

  // ── try body ────────────────────────────────────────────────────────────────
  emitLabel(asm, "try_start")
  emitIload(asm, 0)                          // a
  emitIload(asm, 1)                          // b
  emitIdiv(asm)                              // a/b (ArithmeticException on b=0)
  emitInvokestatic(asm, integerValueOfIdx)   // box int to Integer
  emitAstore(asm, 2)                         // slot 2 = boxed result
  emitNew(asm, okClassIdx)
  emitDup(asm)
  emitAload(asm, 2)
  emitInvokespecial(asm, okCtorIdx)          // Wrapper$Ok(result) on stack
  emitLabel(asm, "try_end")
  emitGoto(asm, "after")

  // ── catch handler ── (ArithmeticException is on stack at entry) ─────────────
  emitLabel(asm, "catch_handler")
  emitAstore(asm, 2)                         // slot 2 = caught exception
  emitNew(asm, errClassIdx)
  emitDup(asm)
  emitAload(asm, 2)
  emitInvokespecial(asm, errCtorIdx)         // Wrapper$Err(exception) on stack

  emitLabel(asm, "after")
  emitAreturn(asm)

  // maxStack=3 (new+dup+load); maxLocals=3 (slot0=a, slot1=b, slot2=boxed/ex)
  val safeDivPs: List[JvmType] = newList()
  safeDivPs.add(JInt)
  safeDivPs.add(JInt)
  val codeAttr = assembleCodeWith1Handler(asm, 3, 3,
    "try_start", "try_end", "catch_handler", aeClassIdx)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val divMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "safeDivide",
    buildDescriptor(safeDivPs, JRef(className = "java/lang/Object")),
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(divMethod)
  val cf = makeClassWithMethodsV49("SafeDiv", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx     = poolFieldref(pool,  "java/lang/System",    "out",           "Ljava/io/PrintStream;")
  val printlnIdx    = poolMethodref(pool, "java/io/PrintStream", "println",        "(Ljava/lang/String;)V")
  val concatIdx     = poolMethodref(pool, "java/lang/String",    "concat",         "(Ljava/lang/String;)Ljava/lang/String;")
  val divideIdx     = poolMethodref(pool, "SafeDiv",             "safeDivide",     "(II)Ljava/lang/Object;")
  val toStringIdx   = poolMethodref(pool, "java/lang/Integer",   "toString",       "()Ljava/lang/String;")
  val getClassIdx   = poolMethodref(pool, "java/lang/Object",    "getClass",       "()Ljava/lang/Class;")
  val simpleNameIdx = poolMethodref(pool, "java/lang/Class",     "getSimpleName",  "()Ljava/lang/String;")

  val okClassIdx    = poolClass(pool, "Wrapper$Ok")
  val errClassIdx   = poolClass(pool, "Wrapper$Err")
  val intClassIdx   = poolClass(pool, "java/lang/Integer")

  val okValueIdx    = poolFieldref(pool, "Wrapper$Ok",  "value", "Ljava/lang/Object;")
  val errErrorIdx   = poolFieldref(pool, "Wrapper$Err", "error", "Ljava/lang/Object;")

  // res1 = safeDivide(10, 2)  →  Wrapper$Ok(Integer(5))
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, divideIdx)
  emitAstore(asm, 1)

  // println("divide(10,2)=ok:" + res1.value.toString())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "divide(10,2)=ok:")
  emitAload(asm, 1)
  emitCheckcast(asm, okClassIdx)
  emitGetfield(asm, okValueIdx)
  emitCheckcast(asm, intClassIdx)
  emitInvokevirtual(asm, toStringIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // res2 = safeDivide(10, 0)  →  Wrapper$Err(ArithmeticException)
  emitPushInt(asm, 10)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, divideIdx)
  emitAstore(asm, 2)

  // println("divide(10,0)=err:" + res2.error.getClass().getSimpleName())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "divide(10,0)=err:")
  emitAload(asm, 2)
  emitCheckcast(asm, errClassIdx)
  emitGetfield(asm, errErrorIdx)
  emitInvokevirtual(asm, getClassIdx)
  emitInvokevirtual(asm, simpleNameIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  // maxStack=3 (getstatic+prefix+aload+checkcast+getfield+...); maxLocals=3 (args, res1, res2)
  val codeAttr = assembleCode(asm, 3, 3)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b127"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val wrapperBytes = makeWrapperBytes()
  val classes: List[BuiltClass] = newList()
  val classNames: List[String] = newList()
  classNames.add("Wrapper")
  classNames.add("Wrapper$Ok")
  classNames.add("Wrapper$Err")
  var i = 0
  while i < wrapperBytes.count {
    classes.add(BuiltClass(binaryName = classNames[i], bytes = wrapperBytes[i]))
    i = i + 1
  }

  classes.add(BuiltClass(binaryName = "SafeDiv", bytes = makeSafeDivBytes()))
  classes.add(BuiltClass(binaryName = "Main",    bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB127",
    mainClass   = "Main",
    version     = "0.1.0",
    outPath     = outDir + "/catch.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
