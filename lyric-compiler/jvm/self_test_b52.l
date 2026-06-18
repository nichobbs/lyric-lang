//! jvm/self_test_b52.l — Stage B52: toString() override with StringBuilder.
//!
//! Generates Point.class with:
//!   int fields x and y
//!   <init>(II)V — stores params into fields
//!   toString()Ljava/lang/String; — builds "Point(x,y)" via StringBuilder
//!
//! Main creates Point(3,5) and prints its toString() → "Point(3,5)".
//!
//! Expected output:
//!   Point(3,5)
//!
//! Exercises: instance field read via getfield inside toString, chained
//!            StringBuilder.append calls mixing String and int args.
package Jvm.SelfTestB52

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makePointClassBytes(): List[Byte] {
  val pool = poolNew()
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")

  val xFieldref = poolFieldref(pool, "Point", "x", "I")
  val yFieldref = poolFieldref(pool, "Point", "y", "I")

  val sbClass = poolClass(pool, "java/lang/StringBuilder")
  val sbInit = poolMethodref(pool, "java/lang/StringBuilder", "<init>", "()V")
  val sbAppendS = poolMethodref(
    pool,
    "java/lang/StringBuilder",
    "append",
    "(Ljava/lang/String;)Ljava/lang/StringBuilder;"
  )
  val sbAppendI = poolMethodref(pool, "java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;")
  val sbToString = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  // ── <init>(II)V ──────────────────────────────────────────────────────────────
  // slot 0 = this, slot 1 = x, slot 2 = y
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitAload(asmInit, 0)
  emitIload(asmInit, 1)
  emitPutfield(asmInit, xFieldref)
  emitAload(asmInit, 0)
  emitIload(asmInit, 2)
  emitPutfield(asmInit, yFieldref)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 2, 3)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "(II)V", initAttrs)

  // ── toString()Ljava/lang/String; ──────────────────────────────────────────────
  // new StringBuilder; dup; invokespecial SB.<init>
  // ldc "Point("; invokevirtual append(String)
  // aload_0; getfield x; invokevirtual append(I)
  // ldc ","; invokevirtual append(String)
  // aload_0; getfield y; invokevirtual append(I)
  // ldc ")"; invokevirtual append(String)
  // invokevirtual toString; areturn
  val asmStr = newAssembler(pool)
  emitNew(asmStr, sbClass)
  emitDup(asmStr)
  emitInvokespecial(asmStr, sbInit)
  emitPushString(asmStr, "Point(")
  emitInvokevirtual(asmStr, sbAppendS)
  emitAload(asmStr, 0)
  emitGetfield(asmStr, xFieldref)
  emitInvokevirtual(asmStr, sbAppendI)
  emitPushString(asmStr, ",")
  emitInvokevirtual(asmStr, sbAppendS)
  emitAload(asmStr, 0)
  emitGetfield(asmStr, yFieldref)
  emitInvokevirtual(asmStr, sbAppendI)
  emitPushString(asmStr, ")")
  emitInvokevirtual(asmStr, sbAppendS)
  emitInvokevirtual(asmStr, sbToString)
  emitAreturn(asmStr)
  val strCode = assembleCode(asmStr, 2, 1)
  val strAttrs: List[Attribute] = newList()
  strAttrs.add(strCode)
  val toStringMethod = makeMethodInfo(ACC_PUBLIC, "toString", "()Ljava/lang/String;", strAttrs)

  // ── fields ───────────────────────────────────────────────────────────────────
  val xField = makeFieldInfo(ACC_PUBLIC, "x", "I", newList())
  val yField = makeFieldInfo(ACC_PUBLIC, "y", "I", newList())
  val fields: List[FieldInfo] = newList()
  fields.add(xField)
  fields.add(yField)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(toStringMethod)
  val cf = makeClassFull("Point", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val pointClass = poolClass(pool, "Point")
  val pointInit = poolMethodref(pool, "Point", "<init>", "(II)V")
  val toStr = poolMethodref(pool, "Point", "toString", "()Ljava/lang/String;")

  // new Point(3, 5) → local 1
  emitNew(asm, pointClass)
  emitDup(asm)
  emitPushInt(asm, 3)
  emitPushInt(asm, 5)
  emitInvokespecial(asm, pointInit)
  emitAstore(asm, 1)

  // println(p.toString())
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitInvokevirtual(asm, toStr)
  emitInvokevirtual(asm, printlnStr)

  emitReturn(asm)

  // maxStack: new(1)+dup(2)+push3(3)+push5(4) peak
  val codeAttr = assembleCode(asm, 4, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b52"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pointBytes = makePointClassBytes()
  val mainBytes = makeMainClassBytes()

  val pointClass = BuiltClass(binaryName = "Point", bytes = pointBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(pointClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB52",
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
