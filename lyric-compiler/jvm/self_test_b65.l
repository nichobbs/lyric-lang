//! jvm/self_test_b65.l — Stage B65: String.charAt + char comparisons.
//!
//! Generates CharOps.class with:
//!   firstChar(String)I      — s.charAt(0) as int
//!   isAsciiDigit(String)I   — 1 if s.charAt(0) in '0'..'9', else 0
//!   isAsciiUpper(String)I   — 1 if s.charAt(0) in 'A'..'Z', else 0
//!
//! Main prints:
//!   firstChar("Hello")     → 72   (ASCII 'H')
//!   firstChar("Z")         → 90   (ASCII 'Z')
//!   isAsciiDigit("7abc")   → 1
//!   isAsciiDigit("abc7")   → 0
//!   isAsciiUpper("Hello")  → 1
//!   isAsciiUpper("hello")  → 0
//!
//! Exercises: invokevirtual String.charAt(I)C, sipush for char constants
//!            (e.g. 'A'=65, 'Z'=90, '0'=48, '9'=57), if_icmplt/if_icmpgt.
package Jvm.SelfTestB65

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCharOpsBytes(): List[Byte] {
  val pool = poolNew()
  val charAtRef = poolMethodref(pool, "java/lang/String", "charAt", "(I)C")

  // firstChar(String)I  — slot 0 = s (String ref)
  val asmFirst = newAssembler(pool)
  emitAload(asmFirst, 0)
  emitIconst(asmFirst, 0)
  emitInvokevirtual(asmFirst, charAtRef)
  emitIreturn(asmFirst)
  val firstCode = assembleCode(asmFirst, 2, 1)
  val firstAttrs: List[Attribute] = newList()
  firstAttrs.add(firstCode)
  val firstMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "firstChar", "(Ljava/lang/String;)I", firstAttrs)

  // isAsciiDigit(String)I
  // '0' = 48, '9' = 57
  // c = s.charAt(0); if c < 48 goto NO; if c > 57 goto NO; iconst_1 goto DONE; NO: iconst_0; DONE: ireturn
  val asmDigit = newAssembler(pool)
  emitAload(asmDigit, 0)
  emitIconst(asmDigit, 0)
  emitInvokevirtual(asmDigit, charAtRef)
  emitIstore(asmDigit, 1)
  emitIload(asmDigit, 1)
  emitPushInt(asmDigit, 48)
  emitIfIcmplt(asmDigit, "DIGIT_NO")
  emitIload(asmDigit, 1)
  emitPushInt(asmDigit, 57)
  emitIfIcmpgt(asmDigit, "DIGIT_NO")
  emitIconst(asmDigit, 1)
  emitGoto(asmDigit, "DIGIT_DONE")
  emitLabel(asmDigit, "DIGIT_NO")
  emitIconst(asmDigit, 0)
  emitLabel(asmDigit, "DIGIT_DONE")
  emitIreturn(asmDigit)
  val digitCode = assembleCode(asmDigit, 2, 2)
  val digitAttrs: List[Attribute] = newList()
  digitAttrs.add(digitCode)
  val digitMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "isAsciiDigit", "(Ljava/lang/String;)I", digitAttrs)

  // isAsciiUpper(String)I
  // 'A' = 65, 'Z' = 90
  val asmUpper = newAssembler(pool)
  emitAload(asmUpper, 0)
  emitIconst(asmUpper, 0)
  emitInvokevirtual(asmUpper, charAtRef)
  emitIstore(asmUpper, 1)
  emitIload(asmUpper, 1)
  emitPushInt(asmUpper, 65)
  emitIfIcmplt(asmUpper, "UPPER_NO")
  emitIload(asmUpper, 1)
  emitPushInt(asmUpper, 90)
  emitIfIcmpgt(asmUpper, "UPPER_NO")
  emitIconst(asmUpper, 1)
  emitGoto(asmUpper, "UPPER_DONE")
  emitLabel(asmUpper, "UPPER_NO")
  emitIconst(asmUpper, 0)
  emitLabel(asmUpper, "UPPER_DONE")
  emitIreturn(asmUpper)
  val upperCode = assembleCode(asmUpper, 2, 2)
  val upperAttrs: List[Attribute] = newList()
  upperAttrs.add(upperCode)
  val upperMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "isAsciiUpper", "(Ljava/lang/String;)I", upperAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(firstMethod)
  methods.add(digitMethod)
  methods.add(upperMethod)
  val cf = makeClassWithMethodsV49("CharOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val firstRef = poolMethodref(pool, "CharOps", "firstChar", "(Ljava/lang/String;)I")
  val digitRef = poolMethodref(pool, "CharOps", "isAsciiDigit", "(Ljava/lang/String;)I")
  val upperRef = poolMethodref(pool, "CharOps", "isAsciiUpper", "(Ljava/lang/String;)I")

  // println(CharOps.firstChar("Hello")) → 72
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Hello")
  emitInvokestatic(asm, firstRef)
  emitInvokevirtual(asm, printlnI)

  // println(CharOps.firstChar("Z")) → 90
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Z")
  emitInvokestatic(asm, firstRef)
  emitInvokevirtual(asm, printlnI)

  // println(CharOps.isAsciiDigit("7abc")) → 1
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "7abc")
  emitInvokestatic(asm, digitRef)
  emitInvokevirtual(asm, printlnI)

  // println(CharOps.isAsciiDigit("abc7")) → 0
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "abc7")
  emitInvokestatic(asm, digitRef)
  emitInvokevirtual(asm, printlnI)

  // println(CharOps.isAsciiUpper("Hello")) → 1
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Hello")
  emitInvokestatic(asm, upperRef)
  emitInvokevirtual(asm, printlnI)

  // println(CharOps.isAsciiUpper("hello")) → 0
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello")
  emitInvokestatic(asm, upperRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+pushString(2) = 2 peak
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
  val outDir = "/tmp/lyric-jvm-b65"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val charOpsBytes = makeCharOpsBytes()
  val mainBytes = makeMainClassBytes()

  val charOpsClass = BuiltClass(binaryName = "CharOps", bytes = charOpsBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(charOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB65",
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
