//! jvm/self_test_b128.l — Stage B128: @externTarget static call with Result wrapping.
//!
//! Validates the bytecode shape that lowerExternTargetBody (codegen.l) emits
//! for a static @externTarget function whose return type is Result[T, JvmException]:
//!   1. Creates a ResultWrapper union (abstract base + Ok/Err case classes).
//!   2. Creates ParseWrapper with a static method tryParseInt(String): Object that
//!      replicates the @externTarget("java.lang.Integer.parseInt") bytecode:
//!        success (valid int string)  → ResultWrapper$Ok(Integer(n))
//!        NumberFormatException       → ResultWrapper$Err(exception)
//!   3. Main calls tryParseInt("42") and tryParseInt("abc") and prints the results.
//!
//! Java output (java -jar):
//!   parse(42)=ok:42
//!   parse(abc)=err:NumberFormatException
package Jvm.SelfTestB128

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build ResultWrapper union (abstract base + Ok/Err case classes) ───────────
func makeResultWrapperBytes(): List[List[Byte]] {
  val pool = poolNew()

  val okFields: List[LField] = newList()
  okFields.add(LField(flags = ACC_PUBLIC, name = "value", fieldType = JRef(className = "java/lang/Object")))

  val errFields: List[LField] = newList()
  errFields.add(LField(flags = ACC_PUBLIC, name = "error", fieldType = JRef(className = "java/lang/Object")))

  val cases: List[LUnionCase] = newList()
  cases.add(LUnionCase(caseName = "Ok", fields = okFields))
  cases.add(LUnionCase(caseName = "Err", fields = errFields))

  val baseMethods: List[LFunc] = newList()
  val u = LUnion(baseName = "ResultWrapper", cases = cases, methods = baseMethods)
  val classFiles = lowerUnion(u, pool)

  val result: List[List[Byte]] = newList()
  var i = 0
  while i < classFiles.count {
    result.add(serializeClassWithPool(classFiles[i], pool))
    i = i + 1
  }
  result
}

// ── Build ParseWrapper class with static tryParseInt ──────────────────────────
//
// Replicates the bytecode lowerExternTargetBody emits for:
//   @externTarget("java.lang.Integer.parseInt")
//   pub func Integer_parseInt(s: in String): Result[Int, JvmException] = ()
//
// Bytecode shape:
//   aload 0                                          // load String param s
//   [try_start]:
//   invokestatic java/lang/Integer.parseInt:(Ljava/lang/String;)I
//   invokestatic java/lang/Integer.valueOf:(I)Ljava/lang/Integer;  // boxIfNeeded
//   astore 1                                         // result slot
//   new ResultWrapper$Ok; dup; aload 1; invokespecial
//   goto [after]
//   [try_end]:
//   [catch_handler]:  // java/lang/Exception on stack
//   astore 2                                         // ex slot
//   new ResultWrapper$Err; dup; aload 2; invokespecial
//   goto [after]
//   LTryCatch(try_start, try_end, catch_handler, "java/lang/Exception")
//   [after]:
//   areturn
func makeParseWrapperBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val parseIntIdx = poolMethodref(pool, "java/lang/Integer", "parseInt", "(Ljava/lang/String;)I")
  val valueOfIdx = poolMethodref(pool, "java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;")
  val okClassIdx = poolClass(pool, "ResultWrapper$Ok")
  val errClassIdx = poolClass(pool, "ResultWrapper$Err")
  val okCtorIdx = poolMethodref(pool, "ResultWrapper$Ok", "<init>", "(Ljava/lang/Object;)V")
  val errCtorIdx = poolMethodref(pool, "ResultWrapper$Err", "<init>", "(Ljava/lang/Object;)V")
  val exClassIdx = poolClass(pool, "java/lang/Exception")

  // Load String param (s at slot 0)
  emitAload(asm, 0)

  // try body
  emitLabel(asm, "try_start")
  emitInvokestatic(asm, parseIntIdx)
  // Integer.parseInt(s) → int
  emitInvokestatic(asm, valueOfIdx)
  // box: int → Integer
  emitAstore(asm, 1)
  // slot 1 = boxed result

  emitNew(asm, okClassIdx)
  emitDup(asm)
  emitAload(asm, 1)
  emitInvokespecial(asm, okCtorIdx)
  emitLabel(asm, "try_end")
  emitGoto(asm, "after")

  // catch handler (java/lang/Exception on stack at entry)
  emitLabel(asm, "catch_handler")
  emitAstore(asm, 2)
  // slot 2 = caught exception

  emitNew(asm, errClassIdx)
  emitDup(asm)
  emitAload(asm, 2)
  emitInvokespecial(asm, errCtorIdx)
  emitGoto(asm, "after")

  emitLabel(asm, "after")
  emitAreturn(asm)

  // maxStack=3; maxLocals=3 (slot0=s, slot1=boxed, slot2=ex)
  val parseSig: List[JvmType] = newList()
  parseSig.add(JRef(className = "java/lang/String"))
  val codeAttr = assembleCodeWith1Handler(asm, 3, 3, "try_start", "try_end", "catch_handler", exClassIdx)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val parseMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "tryParseInt",
    buildDescriptor(parseSig, JRef(className = "java/lang/Object")),
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(parseMethod)
  val cf = makeClassWithMethodsV49("ParseWrapper", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val parseIdx = poolMethodref(pool, "ParseWrapper", "tryParseInt", "(Ljava/lang/String;)Ljava/lang/Object;")
  val toStringIdx = poolMethodref(pool, "java/lang/Integer", "toString", "()Ljava/lang/String;")
  val getClassIdx = poolMethodref(pool, "java/lang/Object", "getClass", "()Ljava/lang/Class;")
  val simpleNameIdx = poolMethodref(pool, "java/lang/Class", "getSimpleName", "()Ljava/lang/String;")
  val okClassIdx = poolClass(pool, "ResultWrapper$Ok")
  val errClassIdx = poolClass(pool, "ResultWrapper$Err")
  val intClassIdx = poolClass(pool, "java/lang/Integer")
  val okValueIdx = poolFieldref(pool, "ResultWrapper$Ok", "value", "Ljava/lang/Object;")
  val errErrorIdx = poolFieldref(pool, "ResultWrapper$Err", "error", "Ljava/lang/Object;")

  // res1 = ParseWrapper.tryParseInt("42")  →  ResultWrapper$Ok(42)
  emitPushString(asm, "42")
  emitInvokestatic(asm, parseIdx)
  emitAstore(asm, 1)

  // println("parse(42)=ok:" + res1.value.toString())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "parse(42)=ok:")
  emitAload(asm, 1)
  emitCheckcast(asm, okClassIdx)
  emitGetfield(asm, okValueIdx)
  emitCheckcast(asm, intClassIdx)
  emitInvokevirtual(asm, toStringIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // res2 = ParseWrapper.tryParseInt("abc")  →  ResultWrapper$Err(NumberFormatException)
  emitPushString(asm, "abc")
  emitInvokestatic(asm, parseIdx)
  emitAstore(asm, 2)

  // println("parse(abc)=err:" + res2.error.getClass().getSimpleName())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "parse(abc)=err:")
  emitAload(asm, 2)
  emitCheckcast(asm, errClassIdx)
  emitGetfield(asm, errErrorIdx)
  emitInvokevirtual(asm, getClassIdx)
  emitInvokevirtual(asm, simpleNameIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  // maxStack=3; maxLocals=3 (args, res1, res2)
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
func main(args: in slice[String]): Int {
  val outDir = if args.length > 0 { args[0] } else { "/tmp/lyric-jvm-b128" }
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val wrapperBytes = makeResultWrapperBytes()
  val classes: List[BuiltClass] = newList()
  val classNames: List[String] = newList()
  classNames.add("ResultWrapper")
  classNames.add("ResultWrapper$Ok")
  classNames.add("ResultWrapper$Err")
  var i = 0
  while i < wrapperBytes.count {
    classes.add(BuiltClass(binaryName = classNames[i], bytes = wrapperBytes[i]))
    i = i + 1
  }

  classes.add(BuiltClass(binaryName = "ParseWrapper", bytes = makeParseWrapperBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB128",
    mainClass = "Main",
    version = "0.1.0",
    outPath = outDir + "/parse.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
  0
}
