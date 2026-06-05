//! jvm/self_test_b76.l — Stage B76: char[] arrays (newarray T_CHAR, caload, castore).
//!
//! Generates CharArrays.class with:
//!   reverse(char[])char[] — allocates new array, copies src reversed
//!   makeHello()char[]     — builds {'H','e','l','l','o'} via castore
//!   fromArray(char[])String — calls new String(char[])
//!
//! Main prints:
//!   fromArray(reverse(makeHello())) → "olleH"
//!
//! Exercises: newarray T_CHAR, castore (store int as char), caload,
//!            arraylength, String constructor taking char[].
package Jvm.SelfTestB76

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCharArraysBytes(): List[Byte] {
  val pool = poolNew()
  val strFromCA = poolMethodref(pool, "java/lang/String", "<init>", "([C)V")
  val strClass = poolClass(pool, "java/lang/String")

  // makeHello()char[]  — builds {'H','e','l','l','o'}
  // H=72, e=101, l=108, l=108, o=111
  val asmHello = newAssembler(pool)
  emitPushInt(asmHello, 5)
  emitNewarray(asmHello, T_CHAR)
  emitAstore(asmHello, 0)
  emitAload(asmHello, 0)
  emitIconst(asmHello, 0)
  emitPushInt(asmHello, 72)
  emitCastore(asmHello)
  emitAload(asmHello, 0)
  emitIconst(asmHello, 1)
  emitPushInt(asmHello, 101)
  emitCastore(asmHello)
  emitAload(asmHello, 0)
  emitPushInt(asmHello, 2)
  emitPushInt(asmHello, 108)
  emitCastore(asmHello)
  emitAload(asmHello, 0)
  emitPushInt(asmHello, 3)
  emitPushInt(asmHello, 108)
  emitCastore(asmHello)
  emitAload(asmHello, 0)
  emitPushInt(asmHello, 4)
  emitPushInt(asmHello, 111)
  emitCastore(asmHello)
  emitAload(asmHello, 0)
  emitAreturn(asmHello)
  // maxStack: aload(1)+int(2)+int(3) = 3 peak for castore
  val helloCode = assembleCode(asmHello, 3, 1)
  val helloAttrs: List[Attribute] = newList()
  helloAttrs.add(helloCode)
  val helloMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeHello", "()[C", helloAttrs)

  // reverse(char[])char[]
  // slot 0=src; slot 1=dst; slot 2=i=0; slot 3=len
  val asmRev = newAssembler(pool)
  emitAload(asmRev, 0)
  emitArraylength(asmRev)
  emitIstore(asmRev, 3)
  emitIload(asmRev, 3)
  emitNewarray(asmRev, T_CHAR)
  emitAstore(asmRev, 1)
  emitIconst(asmRev, 0)
  emitIstore(asmRev, 2)
  emitLabel(asmRev, "REV_LOOP")
  emitIload(asmRev, 2)
  emitIload(asmRev, 3)
  emitIfIcmpge(asmRev, "REV_DONE")
  // dst[i] = src[len-1-i]
  emitAload(asmRev, 1)
  emitIload(asmRev, 2)
  emitAload(asmRev, 0)
  emitIload(asmRev, 3)
  emitIconst(asmRev, 1)
  emitIsub(asmRev)
  emitIload(asmRev, 2)
  emitIsub(asmRev)
  emitCaload(asmRev)
  emitCastore(asmRev)
  emitIinc(asmRev, 2, 1)
  emitGoto(asmRev, "REV_LOOP")
  emitLabel(asmRev, "REV_DONE")
  emitAload(asmRev, 1)
  emitAreturn(asmRev)
  // maxStack: dst(1)+i(2)+src(3)+len(4)+1(5)-i(5)=5 peak; actually
  // aload dst(1)+iload i(2)+aload src(3)+iload len(4)+iconst_1(5) = 5
  val revCode = assembleCode(asmRev, 5, 4)
  val revAttrs: List[Attribute] = newList()
  revAttrs.add(revCode)
  val revMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "reverse", "([C)[C", revAttrs)

  // fromArray(char[])String — new String(char[])
  val asmFrom = newAssembler(pool)
  emitNew(asmFrom, strClass)
  emitDup(asmFrom)
  emitAload(asmFrom, 0)
  emitInvokespecial(asmFrom, strFromCA)
  emitAreturn(asmFrom)
  val fromCode = assembleCode(asmFrom, 3, 1)
  val fromAttrs: List[Attribute] = newList()
  fromAttrs.add(fromCode)
  val fromMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fromArray", "([C)Ljava/lang/String;", fromAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(helloMethod)
  methods.add(revMethod)
  methods.add(fromMethod)
  val cf = makeClassWithMethodsV49("CharArrays", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val helloRef = poolMethodref(pool, "CharArrays", "makeHello", "()[C")
  val revRef = poolMethodref(pool, "CharArrays", "reverse", "([C)[C")
  val fromRef = poolMethodref(pool, "CharArrays", "fromArray", "([C)Ljava/lang/String;")

  // println(CharArrays.fromArray(CharArrays.reverse(CharArrays.makeHello()))) → "olleH"
  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, helloRef)
  emitInvokestatic(asm, revRef)
  emitInvokestatic(asm, fromRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b76"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val charArraysBytes = makeCharArraysBytes()
  val mainBytes = makeMainClassBytes()

  val charArraysClass = BuiltClass(binaryName = "CharArrays", bytes = charArraysBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(charArraysClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB76",
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
