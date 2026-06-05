//! jvm/self_test_b85.l — Stage B85: nested class calls (three-class chain).
//!
//! Generates:
//!   MathOps.class  — add(int,int)int, mul(int,int)int
//!   Formatter.class — format(int)String — calls MathOps.add + MathOps.mul,
//!                     returns "add=%d,mul=%d"
//!
//! Main calls Formatter.format(3, 4) → "add=7,mul=12"
//!
//! Exercises: three-class dependency chain; one class calls another via invokestatic.
package Jvm.SelfTestB85

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathOpsBytes(): List[Byte] {
  val pool = poolNew()

  // add(int a, int b)int
  val asmAdd = newAssembler(pool)
  emitIload(asmAdd, 0)
  emitIload(asmAdd, 1)
  emitIadd(asmAdd)
  emitIreturn(asmAdd)
  val addCode = assembleCode(asmAdd, 2, 2)
  val addAttrs: List[Attribute] = newList()
  addAttrs.add(addCode)
  val addMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "add", "(II)I", addAttrs)

  // mul(int a, int b)int
  val asmMul = newAssembler(pool)
  emitIload(asmMul, 0)
  emitIload(asmMul, 1)
  emitImul(asmMul)
  emitIreturn(asmMul)
  val mulCode = assembleCode(asmMul, 2, 2)
  val mulAttrs: List[Attribute] = newList()
  mulAttrs.add(mulCode)
  val mulMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "mul", "(II)I", mulAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(addMethod)
  methods.add(mulMethod)
  val cf = makeClassWithMethods("MathOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeFormatterBytes(): List[Byte] {
  val pool = poolNew()

  val addRef = poolMethodref(pool, "MathOps", "add", "(II)I")
  val mulRef = poolMethodref(pool, "MathOps", "mul", "(II)I")
  val sbInit = poolMethodref(pool, "java/lang/StringBuilder", "<init>", "()V")
  val sbClass = poolClass(pool, "java/lang/StringBuilder")
  val sbAppendS = poolMethodref(
    pool,
    "java/lang/StringBuilder",
    "append",
    "(Ljava/lang/String;)Ljava/lang/StringBuilder;"
  )
  val sbAppendI = poolMethodref(pool, "java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;")
  val sbToStr = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  // format(int a, int b)String — slot 0=a; slot 1=b
  val asm = newAssembler(pool)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitPushString(asm, "add=")
  emitInvokevirtual(asm, sbAppendS)
  emitIload(asm, 0)
  emitIload(asm, 1)
  emitInvokestatic(asm, addRef)
  emitInvokevirtual(asm, sbAppendI)
  emitPushString(asm, ",mul=")
  emitInvokevirtual(asm, sbAppendS)
  emitIload(asm, 0)
  emitIload(asm, 1)
  emitInvokestatic(asm, mulRef)
  emitInvokevirtual(asm, sbAppendI)
  emitInvokevirtual(asm, sbToStr)
  emitAreturn(asm)
  val code = assembleCode(asm, 4, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "format", "(II)Ljava/lang/String;", attrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)
  val cf = makeClassWithMethods("Formatter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val fmtRef = poolMethodref(pool, "Formatter", "format", "(II)Ljava/lang/String;")

  emitGetstatic(asm, sysOut)
  emitIconst(asm, 3)
  emitIconst(asm, 4)
  emitInvokestatic(asm, fmtRef)
  emitInvokevirtual(asm, printlnS)
  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b85"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val mathOpsBytes = makeMathOpsBytes()
  val formatterBytes = makeFormatterBytes()
  val mainBytes = makeMainClassBytes()

  val mathOpsClass = BuiltClass(binaryName = "MathOps", bytes = mathOpsBytes)
  val formatterClass = BuiltClass(binaryName = "Formatter", bytes = formatterBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathOpsClass)
  classes.add(formatterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB85",
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
