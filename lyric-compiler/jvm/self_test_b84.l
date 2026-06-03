// jvm/self_test_b84.l — Stage B84: String.format with mixed format specifiers.
//
// Generates Formatter.class with:
//   fmtInt(int n)String     — String.format("%d", n)
//   fmtFloat(double d)String — String.format("%.2f", d)
//   fmtBoth(String s, int n)String — String.format("%s=%d", s, n)
//
// Main prints:
//   n=42
//   f=3.14
//   b=x=99
//
// Exercises: String.format(String, Object...) varargs via anewarray,
//            Integer.valueOf(int), Double.valueOf(double), aastore,
//            invokestatic String.format.

package Jvm.SelfTestB84

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFormatterBytes(): List[Byte] {
  val pool = poolNew()

  val strFormat   = poolMethodref(pool, "java/lang/String",  "format",
    "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;")
  val intValueOf  = poolMethodref(pool, "java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;")
  val dblValueOf  = poolMethodref(pool, "java/lang/Double",  "valueOf", "(D)Ljava/lang/Double;")
  val objArrClass = poolClass(pool, "java/lang/Object")

  // fmtInt(int n)String  slot 0=n
  // String.format("%d", new Object[]{Integer.valueOf(n)})
  val asmI = newAssembler(pool)
  emitPushString(asmI, "%d")
  emitIconst(asmI, 1)
  emitAnewarray(asmI, objArrClass)
  emitDup(asmI)
  emitIconst(asmI, 0)
  emitIload(asmI, 0)
  emitInvokestatic(asmI, intValueOf)
  emitAastore(asmI)
  emitInvokestatic(asmI, strFormat)
  emitAreturn(asmI)
  val iCode = assembleCode(asmI, 5, 1)
  val iAttrs: List[Attribute] = newList()
  iAttrs.add(iCode)
  val iMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fmtInt",
    "(I)Ljava/lang/String;", iAttrs)

  // fmtFloat(double d)String  slot 0+1=d (double takes 2 slots)
  // String.format("%.2f", new Object[]{Double.valueOf(d)})
  val asmF = newAssembler(pool)
  emitPushString(asmF, "%.2f")
  emitIconst(asmF, 1)
  emitAnewarray(asmF, objArrClass)
  emitDup(asmF)
  emitIconst(asmF, 0)
  emitDload(asmF, 0)
  emitInvokestatic(asmF, dblValueOf)
  emitAastore(asmF)
  emitInvokestatic(asmF, strFormat)
  emitAreturn(asmF)
  val fCode = assembleCode(asmF, 6, 2)
  val fAttrs: List[Attribute] = newList()
  fAttrs.add(fCode)
  val fMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fmtFloat",
    "(D)Ljava/lang/String;", fAttrs)

  // fmtBoth(String s, int n)String  slot 0=s; slot 1=n
  // String.format("%s=%d", new Object[]{s, Integer.valueOf(n)})
  val asmB = newAssembler(pool)
  emitPushString(asmB, "%s=%d")
  emitPushInt(asmB, 2)
  emitAnewarray(asmB, objArrClass)
  emitDup(asmB)
  emitIconst(asmB, 0)
  emitAload(asmB, 0)
  emitAastore(asmB)
  emitDup(asmB)
  emitIconst(asmB, 1)
  emitIload(asmB, 1)
  emitInvokestatic(asmB, intValueOf)
  emitAastore(asmB)
  emitInvokestatic(asmB, strFormat)
  emitAreturn(asmB)
  val bCode = assembleCode(asmB, 5, 2)
  val bAttrs: List[Attribute] = newList()
  bAttrs.add(bCode)
  val bMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fmtBoth",
    "(Ljava/lang/String;I)Ljava/lang/String;", bAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(iMethod)
  methods.add(fMethod)
  methods.add(bMethod)
  val cf = makeClassWithMethods("Formatter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val fmtIntRef = poolMethodref(pool, "Formatter", "fmtInt",   "(I)Ljava/lang/String;")
  val fmtFltRef = poolMethodref(pool, "Formatter", "fmtFloat", "(D)Ljava/lang/String;")
  val fmtBthRef = poolMethodref(pool, "Formatter", "fmtBoth",  "(Ljava/lang/String;I)Ljava/lang/String;")

  // println("n=" + fmtInt(42))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "n=")
  emitPushInt(asm, 42)
  emitInvokestatic(asm, fmtIntRef)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("f=" + fmtFloat(3.14))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "f=")
  emitPushDouble(asm, 3.14)
  emitInvokestatic(asm, fmtFltRef)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  // println("b=" + fmtBoth("x", 99))
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "b=")
  emitPushString(asm, "x")
  emitPushInt(asm, 99)
  emitInvokestatic(asm, fmtBthRef)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b84"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val formatterBytes = makeFormatterBytes()
  val mainBytes      = makeMainClassBytes()

  val formatterClass = BuiltClass(binaryName = "Formatter", bytes = formatterBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(formatterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB84",
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
