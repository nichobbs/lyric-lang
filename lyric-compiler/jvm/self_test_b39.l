//! jvm/self_test_b39.l — Stage B39: JDK utility calls (Integer.parseInt, String.valueOf).
//!
//! Generates Converter.class with:
//!   parseAndDouble(Ljava/lang/String;)I
//!       — Integer.parseInt(s), multiply by 2, return
//!   intToStr(I)Ljava/lang/String;
//!       — String.valueOf(n), return
//!
//! Main:
//!   parseAndDouble("21") → 42
//!   intToStr(99)         → "99"
//!
//! Expected output lines:
//!   42
//!   99
//!
//! Exercises: invokestatic on JDK methods (Integer.parseInt, String.valueOf),
//! mixing int and String return values in a single class.
package Jvm.SelfTestB39

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeConverterClassBytes(): List[Byte] {
  val pool = poolNew()

  val parseIntRef = poolMethodref(pool, "java/lang/Integer", "parseInt", "(Ljava/lang/String;)I")
  val valueOfRef = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  // ── parseAndDouble(Ljava/lang/String;)I ──────────────────────────────────────
  // aload_0; invokestatic Integer.parseInt; iconst_2; imul; ireturn
  val asmPAD = newAssembler(pool)
  emitAload(asmPAD, 0)
  emitInvokestatic(asmPAD, parseIntRef)
  emitPushInt(asmPAD, 2)
  emitImul(asmPAD)
  emitIreturn(asmPAD)
  val padCode = assembleCode(asmPAD, 2, 1)
  val padAttrs: List[Attribute] = newList()
  padAttrs.add(padCode)
  val padMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "parseAndDouble", "(Ljava/lang/String;)I", padAttrs)

  // ── intToStr(I)Ljava/lang/String; ────────────────────────────────────────────
  // iload_0; invokestatic String.valueOf(I); areturn
  val asmITS = newAssembler(pool)
  emitIload(asmITS, 0)
  emitInvokestatic(asmITS, valueOfRef)
  emitAreturn(asmITS)
  val itsCode = assembleCode(asmITS, 1, 1)
  val itsAttrs: List[Attribute] = newList()
  itsAttrs.add(itsCode)
  val itsMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "intToStr", "(I)Ljava/lang/String;", itsAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(padMethod)
  methods.add(itsMethod)
  val cf = makeClassWithMethods("Converter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val padRef = poolMethodref(pool, "Converter", "parseAndDouble", "(Ljava/lang/String;)I")
  val itsRef = poolMethodref(pool, "Converter", "intToStr", "(I)Ljava/lang/String;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // parseAndDouble("21") → 42
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "21")
  emitInvokestatic(asm, padRef)
  emitInvokevirtual(asm, printlnI)

  // intToStr(99) → "99"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 99)
  emitInvokestatic(asm, itsRef)
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
  val outDir = "/tmp/lyric-jvm-b39"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val converterBytes = makeConverterClassBytes()
  val mainBytes = makeMainClassBytes()

  val converterClass = BuiltClass(binaryName = "Converter", bytes = converterBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(converterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB39",
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
