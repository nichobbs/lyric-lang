//! jvm/self_test_b110.l — Stage B110: lowerOpaqueType (opaque-type wrapper codegen).
//!
//! Creates an opaque type `OpaquePoint` with two int fields: x and y.
//! The class has:
//!   • private final synthetic `$x` and `$y` fields
//!   • a package-private constructor `<init>(int, int)V`
//!   • public bootstrap-grade accessors `$x()I` and `$y()I`
//!
//! A Main class:
//!   - Constructs OpaquePoint(3, 4) → prints point.$x=3 and point.$y=4
//!   - Constructs OpaquePoint(0, 0) → prints origin.$x=0 and origin.$y=0
//!
//! Java output (java -jar):
//!   point.$x=3
//!   point.$y=4
//!   origin.$x=0
//!   origin.$y=0
package Jvm.SelfTestB110

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build OpaquePoint class ───────────────────────────────────────────────────
func makeOpaquePointBytes(): List[Byte] {
  val pool = poolNew()
  val flds: List[LOpaqueField] = newList()
  flds.add(LOpaqueField(name = "x", fieldType = JInt))
  flds.add(LOpaqueField(name = "y", fieldType = JInt))
  val cf = lowerOpaqueType(LOpaqueType(className = "OpaquePoint", fields = flds), pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  val ptNewIdx = poolClass(pool, "OpaquePoint")
  val ptCtorIdx = poolMethodref(pool, "OpaquePoint", "<init>", "(II)V")
  val ptXIdx = poolMethodref(pool, "OpaquePoint", "$x", "()I")
  val ptYIdx = poolMethodref(pool, "OpaquePoint", "$y", "()I")

  // OpaquePoint point = new OpaquePoint(3, 4)
  emitNew(asm, ptNewIdx)
  emitDup(asm)
  emitPushInt(asm, 3)
  emitPushInt(asm, 4)
  emitInvokespecial(asm, ptCtorIdx)
  emitAstore(asm, 1)

  // println("point.$x=" + point.$x())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "point.$x=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, ptXIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("point.$y=" + point.$y())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "point.$y=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, ptYIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // OpaquePoint origin = new OpaquePoint(0, 0)
  emitNew(asm, ptNewIdx)
  emitDup(asm)
  emitPushInt(asm, 0)
  emitPushInt(asm, 0)
  emitInvokespecial(asm, ptCtorIdx)
  emitAstore(asm, 2)

  // println("origin.$x=" + origin.$x())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "origin.$x=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, ptXIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("origin.$y=" + origin.$y())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "origin.$y=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, ptYIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  // maxStack=4 (new+dup+push+push for ctor, or getstatic+ldc+aload+invokevirtual+invokestatic+invokevirtual)
  // maxLocals=3 (slot 0=args, slot 1=point, slot 2=origin)
  val codeAttr = assembleCode(asm, 4, 3)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────
func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b110"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "OpaquePoint", bytes = makeOpaquePointBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB110",
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
