//! jvm/self_test_b111.l — Stage B111: lowerSealedUnion (production sealed-interface form).
//!
//! Creates a sealed union `Shape` with two cases:
//!   Shape$Circle: public final float radius
//!   Shape$Rect:   public final float w, h
//!
//! A Main class:
//!   - Constructs Shape$Circle(1.5) → prints "circle.radius=1.5"
//!   - Constructs Shape$Rect(3.0, 4.0) → prints "rect.area=12.0"
//!
//! Java output (java -jar):
//!   circle.radius=1.5
//!   rect.area=12.0
package Jvm.SelfTestB111

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Shape sealed union ──────────────────────────────────────────────────
func makeShapeClasses(pool: in Pool): List[BuiltClass] {
  val circleFields: List[LField] = newList()
  circleFields.add(LField(flags = ACC_PUBLIC, name = "radius", fieldType = JFloat))

  val rectFields: List[LField] = newList()
  rectFields.add(LField(flags = ACC_PUBLIC, name = "w", fieldType = JFloat))
  rectFields.add(LField(flags = ACC_PUBLIC, name = "h", fieldType = JFloat))

  val cases: List[LSealedCase] = newList()
  cases.add(LSealedCase(caseName = "Circle", fields = circleFields))
  cases.add(LSealedCase(caseName = "Rect", fields = rectFields))

  val su = LSealedUnion(baseName = "Shape", cases = cases)
  val cfs = lowerSealedUnion(su, pool)

  val result: List[BuiltClass] = newList()
  for cf in cfs.toArray() {
    result.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
  }
  result
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val vofFIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(F)Ljava/lang/String;")

  val circleClass = poolClass(pool, "Shape$Circle")
  val circleCtor = poolMethodref(pool, "Shape$Circle", "<init>", "(F)V")
  val radiusField = poolFieldref(pool, "Shape$Circle", "radius", "F")

  val rectClass = poolClass(pool, "Shape$Rect")
  val rectCtor = poolMethodref(pool, "Shape$Rect", "<init>", "(FF)V")
  val wField = poolFieldref(pool, "Shape$Rect", "w", "F")
  val hField = poolFieldref(pool, "Shape$Rect", "h", "F")

  // Shape$Circle circle = new Shape$Circle(1.5f)
  emitNew(asm, circleClass)
  emitDup(asm)
  emitPushFloat(asm, 1.5)
  emitInvokespecial(asm, circleCtor)
  emitAstore(asm, 1)

  // println("circle.radius=" + circle.radius)
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "circle.radius=")
  emitAload(asm, 1)
  emitGetfield(asm, radiusField)
  emitInvokestatic(asm, vofFIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // Shape$Rect rect = new Shape$Rect(3.0f, 4.0f)
  emitNew(asm, rectClass)
  emitDup(asm)
  emitPushFloat(asm, 3.0)
  emitPushFloat(asm, 4.0)
  emitInvokespecial(asm, rectCtor)
  emitAstore(asm, 2)

  // println("rect.area=" + (rect.w * rect.h))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "rect.area=")
  emitAload(asm, 2)
  emitGetfield(asm, wField)
  emitAload(asm, 2)
  emitGetfield(asm, hField)
  emitFmul(asm)
  emitInvokestatic(asm, vofFIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 3)
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
  val outDir = "/tmp/lyric-jvm-b111"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  for bc in makeShapeClasses(pool).toArray() {
    classes.add(bc)
  }
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB111",
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
