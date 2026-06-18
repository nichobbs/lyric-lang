// jvm/self_test_b49.l — Stage B49: String.format with an Object[] argument array.
//
// Generates Formatter.class with:
//   formatInt(I)Ljava/lang/String; — String.format("value=%d", new Object[]{Integer.valueOf(n)})
//
// Main prints:
//   formatInt(7)  → "value=7"
//   formatInt(99) → "value=99"
//
// Exercises: anewarray java/lang/Object, aastore, Integer.valueOf boxing,
//            invokestatic String.format(String,Object[])String.

package Jvm.SelfTestB49

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFormatterClassBytes(): List[Byte] {
  val pool = poolNew()

  val stringFormat = poolMethodref(pool, "java/lang/String", "format", "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;")
  val intValueOf   = poolMethodref(pool, "java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;")
  val objClass     = poolClass(pool, "java/lang/Object")

  // ── formatInt(I)Ljava/lang/String; ───────────────────────────────────────────
  // slot 0 = n (int)
  // ldc "value=%d"
  // iconst_1
  // anewarray java/lang/Object   → Object[1]
  // dup
  // iconst_0
  // iload_0; Integer.valueOf(n)  → boxed int
  // aastore                       → arr[0] = boxed n
  // invokestatic String.format("value=%d", arr)
  // areturn
  val asmFmt = newAssembler(pool)
  emitPushString(asmFmt, "value=%d")
  emitPushInt(asmFmt, 1)
  emitAnewarray(asmFmt, objClass)
  emitDup(asmFmt)
  emitIconst(asmFmt, 0)
  emitIload(asmFmt, 0)
  emitInvokestatic(asmFmt, intValueOf)
  emitAastore(asmFmt)
  emitInvokestatic(asmFmt, stringFormat)
  emitAreturn(asmFmt)

  // maxStack: ldc(1), iconst_1(2), anewarray(1), dup(2), iconst_0(3), iload_0(4→but also String on stack: 1+1+1+1+1=5)
  // ldc "value=%d" [1], iconst_1 [2], anewarray [1+1=2], dup [3], iconst_0 [4], iload_0 [5], valueOf [5], aastore pops 3 [2], format pops 2 [0]
  // Wait: after dup → [String, Object[], Object[]] = 3; iconst_0 → [String, Object[], Object[], int] = 4;
  //        iload_0 → [String, Object[], Object[], int, int] = 5
  // maxStack = 5
  val fmtCode = assembleCode(asmFmt, 5, 1)
  val fmtAttrs: List[Attribute] = newList()
  fmtAttrs.add(fmtCode)
  val fmtMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "formatInt", "(I)Ljava/lang/String;", fmtAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(fmtMethod)
  val cf = makeClassWithMethods("Formatter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val fmtRef     = poolMethodref(pool, "Formatter", "formatInt", "(I)Ljava/lang/String;")

  // println(Formatter.formatInt(7))   → "value=7"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 7)
  emitInvokestatic(asm, fmtRef)
  emitInvokevirtual(asm, printlnStr)

  // println(Formatter.formatInt(99))  → "value=99"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 99)
  emitInvokestatic(asm, fmtRef)
  emitInvokevirtual(asm, printlnStr)

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
  val outDir = "/tmp/lyric-jvm-b49"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val formatterBytes = makeFormatterClassBytes()
  val mainBytes      = makeMainClassBytes()

  val formatterClass = BuiltClass(binaryName = "Formatter", bytes = formatterBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(formatterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB49",
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
