// jvm/self_test_b70.l — Stage B70: String.split + aaload (reference array element).
//
// Generates Splitter.class with:
//   splitFirst(String,String)String  — splits s on delim, returns [0]
//   splitSecond(String,String)String — splits s on delim, returns [1]
//   splitCount(String,String)I       — splits s on delim, returns length
//
// Main prints:
//   splitFirst("hello,world", ",")  → "hello"
//   splitSecond("hello,world", ",") → "world"
//   splitCount("a:b:c", ":")        → 3
//
// Exercises: invokevirtual String.split, arraylength, aaload, areturn.

package Jvm.SelfTestB70

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeSplitterBytes(): List[Byte] {
  val pool       = poolNew()
  val splitRef   = poolMethodref(pool, "java/lang/String", "split", "(Ljava/lang/String;)[Ljava/lang/String;")

  // splitFirst(String,String)String  — slot 0=s, slot 1=delim
  val asmFirst = newAssembler(pool)
  emitAload(asmFirst, 0)
  emitAload(asmFirst, 1)
  emitInvokevirtual(asmFirst, splitRef)
  emitIconst(asmFirst, 0)
  emitAaload(asmFirst)
  emitAreturn(asmFirst)
  val firstCode = assembleCode(asmFirst, 2, 2)
  val firstAttrs: List[Attribute] = newList()
  firstAttrs.add(firstCode)
  val firstMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "splitFirst",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", firstAttrs)

  // splitSecond(String,String)String
  val asmSecond = newAssembler(pool)
  emitAload(asmSecond, 0)
  emitAload(asmSecond, 1)
  emitInvokevirtual(asmSecond, splitRef)
  emitIconst(asmSecond, 1)
  emitAaload(asmSecond)
  emitAreturn(asmSecond)
  val secondCode = assembleCode(asmSecond, 2, 2)
  val secondAttrs: List[Attribute] = newList()
  secondAttrs.add(secondCode)
  val secondMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "splitSecond",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", secondAttrs)

  // splitCount(String,String)I
  val asmCount = newAssembler(pool)
  emitAload(asmCount, 0)
  emitAload(asmCount, 1)
  emitInvokevirtual(asmCount, splitRef)
  emitArraylength(asmCount)
  emitIreturn(asmCount)
  val countCode = assembleCode(asmCount, 2, 2)
  val countAttrs: List[Attribute] = newList()
  countAttrs.add(countCode)
  val countMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "splitCount",
    "(Ljava/lang/String;Ljava/lang/String;)I", countAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(firstMethod)
  methods.add(secondMethod)
  methods.add(countMethod)
  val cf = makeClassWithMethods("Splitter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool       = poolNew()
  val asm        = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS   = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val printlnI   = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val firstRef   = poolMethodref(pool, "Splitter", "splitFirst",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val secondRef  = poolMethodref(pool, "Splitter", "splitSecond",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val countRef   = poolMethodref(pool, "Splitter", "splitCount",
    "(Ljava/lang/String;Ljava/lang/String;)I")

  // println(Splitter.splitFirst("hello,world", ",")) → "hello"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello,world")
  emitPushString(asm, ",")
  emitInvokestatic(asm, firstRef)
  emitInvokevirtual(asm, printlnS)

  // println(Splitter.splitSecond("hello,world", ",")) → "world"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello,world")
  emitPushString(asm, ",")
  emitInvokestatic(asm, secondRef)
  emitInvokevirtual(asm, printlnS)

  // println(Splitter.splitCount("a:b:c", ":")) → 3
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "a:b:c")
  emitPushString(asm, ":")
  emitInvokestatic(asm, countRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+pushStr(2)+pushStr(3) = 3 peak
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
  val outDir = "/tmp/lyric-jvm-b70"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val splitterBytes = makeSplitterBytes()
  val mainBytes     = makeMainClassBytes()

  val splitterClass = BuiltClass(binaryName = "Splitter", bytes = splitterBytes)
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(splitterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB70",
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
