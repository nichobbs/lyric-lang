//! jvm/self_test_b21.l — Stage B21: String concatenation via StringBuilder.
//!
//! Generates a class with a concat(String, String) static helper that uses
//! StringBuilder to concatenate two strings, demonstrating the JVM lowering
//! pattern for Lyric's `+` operator on String.
//!
//! Exercises: new StringBuilder, invokespecial <init>()V,
//! invokevirtual append(String)LStringBuilder, invokevirtual toString()String.
package Jvm.SelfTestB21

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeStrUtilClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // concat(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
  //   new StringBuilder
  //   dup
  //   invokespecial StringBuilder.<init>()V
  //   aload_0               (first string)
  //   invokevirtual StringBuilder.append(String)LStringBuilder;
  //   aload_1               (second string)
  //   invokevirtual StringBuilder.append(String)LStringBuilder;
  //   invokevirtual StringBuilder.toString()String
  //   areturn

  val sbClass = poolClass(pool, "java/lang/StringBuilder")
  val sbInit = poolMethodref(pool, "java/lang/StringBuilder", "<init>", "()V")
  val sbAppend = poolMethodref(
    pool,
    "java/lang/StringBuilder",
    "append",
    "(Ljava/lang/String;)Ljava/lang/StringBuilder;"
  )
  val sbToStr = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitAload(asm, 0)
  emitInvokevirtual(asm, sbAppend)
  emitAload(asm, 1)
  emitInvokevirtual(asm, sbAppend)
  emitInvokevirtual(asm, sbToStr)
  emitAreturn(asm)

  val codeAttr = assembleCode(asm, 3, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val concatMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "concat",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(concatMethod)
  val cf = makeClassWithMethods("StrUtil", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val concatRef = poolMethodref(pool, "StrUtil", "concat", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello ")
  emitPushString(asm, "from b21")
  emitInvokestatic(asm, concatRef)
  emitInvokevirtual(asm, println_)
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
  val outDir = "/tmp/lyric-jvm-b21"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val strUtilBytes = makeStrUtilClassBytes()
  val mainBytes = makeMainClassBytes()

  val strUtilClass = BuiltClass(binaryName = "StrUtil", bytes = strUtilBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(strUtilClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB21",
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
