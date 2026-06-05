//! jvm/self_test_b59.l — Stage B59: Integer static string-conversion methods.
//!
//! Generates Converter.class with three static methods:
//!   toBin(I)String  — Integer.toBinaryString(i)
//!   toHex(I)String  — Integer.toHexString(i)
//!   toOct(I)String  — Integer.toOctalString(i)
//!
//! Main prints:
//!   toBin(10)  → "1010"
//!   toHex(255) → "ff"
//!   toOct(8)   → "10"
//!
//! Exercises: invokestatic on java/lang/Integer for string-conversion builtins,
//!            areturn of String result.
package Jvm.SelfTestB59

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeConverterBytes(): List[Byte] {
  val pool = poolNew()
  val toBinRef = poolMethodref(pool, "java/lang/Integer", "toBinaryString", "(I)Ljava/lang/String;")
  val toHexRef = poolMethodref(pool, "java/lang/Integer", "toHexString", "(I)Ljava/lang/String;")
  val toOctRef = poolMethodref(pool, "java/lang/Integer", "toOctalString", "(I)Ljava/lang/String;")

  // toBin(I)String
  val asmBin = newAssembler(pool)
  emitIload(asmBin, 0)
  emitInvokestatic(asmBin, toBinRef)
  emitAreturn(asmBin)
  val binCode = assembleCode(asmBin, 1, 1)
  val binAttrs: List[Attribute] = newList()
  binAttrs.add(binCode)
  val binMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "toBin", "(I)Ljava/lang/String;", binAttrs)

  // toHex(I)String
  val asmHex = newAssembler(pool)
  emitIload(asmHex, 0)
  emitInvokestatic(asmHex, toHexRef)
  emitAreturn(asmHex)
  val hexCode = assembleCode(asmHex, 1, 1)
  val hexAttrs: List[Attribute] = newList()
  hexAttrs.add(hexCode)
  val hexMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "toHex", "(I)Ljava/lang/String;", hexAttrs)

  // toOct(I)String
  val asmOct = newAssembler(pool)
  emitIload(asmOct, 0)
  emitInvokestatic(asmOct, toOctRef)
  emitAreturn(asmOct)
  val octCode = assembleCode(asmOct, 1, 1)
  val octAttrs: List[Attribute] = newList()
  octAttrs.add(octCode)
  val octMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "toOct", "(I)Ljava/lang/String;", octAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(binMethod)
  methods.add(hexMethod)
  methods.add(octMethod)
  val cf = makeClassWithMethods("Converter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val toBinRef = poolMethodref(pool, "Converter", "toBin", "(I)Ljava/lang/String;")
  val toHexRef = poolMethodref(pool, "Converter", "toHex", "(I)Ljava/lang/String;")
  val toOctRef = poolMethodref(pool, "Converter", "toOct", "(I)Ljava/lang/String;")

  // println(Converter.toBin(10))  → "1010"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, toBinRef)
  emitInvokevirtual(asm, printlnS)

  // println(Converter.toHex(255)) → "ff"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 255)
  emitInvokestatic(asm, toHexRef)
  emitInvokevirtual(asm, printlnS)

  // println(Converter.toOct(8))   → "10"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 8)
  emitInvokestatic(asm, toOctRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  // maxStack: getstatic(1) + push(2) + invokestatic→String(2) = 2 peak
  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b59"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val converterBytes = makeConverterBytes()
  val mainBytes = makeMainClassBytes()

  val converterClass = BuiltClass(binaryName = "Converter", bytes = converterBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(converterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB59",
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
