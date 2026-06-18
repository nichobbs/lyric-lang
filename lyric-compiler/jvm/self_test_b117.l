//! jvm/self_test_b117.l — Stage B117: lowerProjectable (@projectable opaque type + view twin).
//!
//! Creates an opaque type `Temperature` with a JFloat celsius field,
//! paired with a view twin `TemperatureView` (exposed record, unmangled celsius field).
//! The opaque class gets a `toView(): TemperatureView` method.
//!
//! A Main class constructs Temperature(36.6), calls toView(), prints celsius.
//!
//! Java output (java -jar):
//!   view.celsius=36.6
package Jvm.SelfTestB117

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Temperature (projectable) + TemperatureView ────────────────────────
func makeTemperatureClasses(pool: in Pool): List[BuiltClass] {
  val fields: List[LOpaqueField] = newList()
  fields.add(LOpaqueField(name = "celsius", fieldType = JFloat))

  val p = LProjectable(opaqueTypeName = "Temperature", viewTypeName = "TemperatureView", fields = fields)
  val cfs = lowerProjectable(p, pool)

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

  val tempClass = poolClass(pool, "Temperature")
  val tempCtor = poolMethodref(pool, "Temperature", "<init>", "(F)V")
  val toViewRef = poolMethodref(pool, "Temperature", "toView", "()LTemperatureView;")
  val celsiusAcc = poolMethodref(pool, "TemperatureView", "celsius", "()F")

  // Temperature t = new Temperature(36.6f)
  emitNew(asm, tempClass)
  emitDup(asm)
  emitPushFloat(asm, 36.6)
  emitInvokespecial(asm, tempCtor)
  emitAstore(asm, 1)

  // TemperatureView view = t.toView()
  emitAload(asm, 1)
  emitInvokevirtual(asm, toViewRef)
  emitAstore(asm, 2)

  // println("view.celsius=" + view.celsius())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "view.celsius=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, celsiusAcc)
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
  val outDir = "/tmp/lyric-jvm-b117"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  for bc in makeTemperatureClasses(pool).toArray() {
    classes.add(bc)
  }
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB117",
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
