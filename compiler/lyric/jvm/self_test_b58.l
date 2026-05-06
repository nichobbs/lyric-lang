// jvm/self_test_b58.l — Stage B58: union dispatch via instanceof + checkcast.
//
// Generates an abstract Shape hierarchy:
//   Shape.class    — abstract base
//   Circle.class   — extends Shape; int radius field; area = radius*radius
//   Rectangle.class — extends Shape; int width + height fields; area = width*height
//   Measurer.class  — static area(Shape)I dispatches via instanceof
//
// Main prints:
//   area(new Circle(5))       → 25
//   area(new Rectangle(3,4))  → 12
//
// Exercises: instanceof (ifeq branch), checkcast, getfield on cast object,
//            two-return method with early ireturn path.

package Jvm.SelfTestB58

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeShapeBytes(): List[Byte] {
  val pool    = poolNew()
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeAbstractClass("Shape", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeCircleBytes(): List[Byte] {
  val pool       = poolNew()
  val shapeInit  = poolMethodref(pool, "Shape", "<init>", "()V")
  val radiusRef  = poolFieldref(pool, "Circle", "radius", "I")

  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, shapeInit)
  emitAload(asmInit, 0)
  emitIload(asmInit, 1)
  emitPutfield(asmInit, radiusRef)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 2, 2)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "(I)V", initAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  val radiusField = makeFieldInfo(ACC_PUBLIC, "radius", "I", newList())
  val fields: List[FieldInfo] = newList()
  fields.add(radiusField)
  val cf = makeCaseClass("Circle", "Shape", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeRectangleBytes(): List[Byte] {
  val pool      = poolNew()
  val shapeInit = poolMethodref(pool, "Shape", "<init>", "()V")
  val widthRef  = poolFieldref(pool, "Rectangle", "width",  "I")
  val heightRef = poolFieldref(pool, "Rectangle", "height", "I")

  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, shapeInit)
  emitAload(asmInit, 0)
  emitIload(asmInit, 1)
  emitPutfield(asmInit, widthRef)
  emitAload(asmInit, 0)
  emitIload(asmInit, 2)
  emitPutfield(asmInit, heightRef)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 2, 3)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "(II)V", initAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  val widthField  = makeFieldInfo(ACC_PUBLIC, "width",  "I", newList())
  val heightField = makeFieldInfo(ACC_PUBLIC, "height", "I", newList())
  val fields: List[FieldInfo] = newList()
  fields.add(widthField)
  fields.add(heightField)
  val cf = makeCaseClass("Rectangle", "Shape", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMeasurerBytes(): List[Byte] {
  val pool        = poolNew()
  val circleClass = poolClass(pool, "Circle")
  val rectClass   = poolClass(pool, "Rectangle")
  val radiusRef   = poolFieldref(pool, "Circle", "radius", "I")
  val widthRef    = poolFieldref(pool, "Rectangle", "width",  "I")
  val heightRef   = poolFieldref(pool, "Rectangle", "height", "I")

  // ── area(Shape)I ─────────────────────────────────────────────────────────────
  // slot 0 = shape (Shape ref)
  // aload_0; instanceof Circle; ifeq NOT_CIRCLE
  // aload_0; checkcast Circle; getfield radius; dup; imul; ireturn
  // NOT_CIRCLE:
  // aload_0; checkcast Rectangle; astore_1
  // aload_1; getfield width; aload_1; getfield height; imul; ireturn
  val asm = newAssembler(pool)
  emitAload(asm, 0)
  emitInstanceof(asm, circleClass)
  emitIfeq(asm, "NOT_CIRCLE")
  // Circle branch:
  emitAload(asm, 0)
  emitCheckcast(asm, circleClass)
  emitGetfield(asm, radiusRef)    // radius
  emitDup(asm)
  emitImul(asm)                   // radius * radius
  emitIreturn(asm)
  // Rectangle branch:
  emitLabel(asm, "NOT_CIRCLE")
  emitAload(asm, 0)
  emitCheckcast(asm, rectClass)
  emitAstore(asm, 1)
  emitAload(asm, 1)
  emitGetfield(asm, widthRef)     // width
  emitAload(asm, 1)
  emitGetfield(asm, heightRef)    // height
  emitImul(asm)                   // width * height
  emitIreturn(asm)

  // maxStack: aload(1) + instanceof(1) or checkcast+getfield+dup(2) peak
  val areaCode = assembleCode(asm, 2, 2)
  val areaAttrs: List[Attribute] = newList()
  areaAttrs.add(areaCode)
  val areaMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "area", "(LShape;)I", areaAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(areaMethod)
  val cf = makeClassWithMethodsV49("Measurer", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut       = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI     = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val areaRef      = poolMethodref(pool, "Measurer", "area", "(LShape;)I")
  val circleClass  = poolClass(pool, "Circle")
  val circleInit   = poolMethodref(pool, "Circle", "<init>", "(I)V")
  val rectClass    = poolClass(pool, "Rectangle")
  val rectInit     = poolMethodref(pool, "Rectangle", "<init>", "(II)V")

  // println(Measurer.area(new Circle(5)))     → 25
  emitGetstatic(asm, sysOut)
  emitNew(asm, circleClass)
  emitDup(asm)
  emitPushInt(asm, 5)
  emitInvokespecial(asm, circleInit)
  emitInvokestatic(asm, areaRef)
  emitInvokevirtual(asm, printlnI)

  // println(Measurer.area(new Rectangle(3,4))) → 12
  emitGetstatic(asm, sysOut)
  emitNew(asm, rectClass)
  emitDup(asm)
  emitPushInt(asm, 3)
  emitPushInt(asm, 4)
  emitInvokespecial(asm, rectInit)
  emitInvokestatic(asm, areaRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+new(2)+dup(3)+push3(4)+push4(5) peak for Rectangle
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
  val outDir = "/tmp/lyric-jvm-b58"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val shapeBytes     = makeShapeBytes()
  val circleBytes    = makeCircleBytes()
  val rectangleBytes = makeRectangleBytes()
  val measurerBytes  = makeMeasurerBytes()
  val mainBytes      = makeMainClassBytes()

  val shapeClass     = BuiltClass(binaryName = "Shape",     bytes = shapeBytes)
  val circleClass    = BuiltClass(binaryName = "Circle",    bytes = circleBytes)
  val rectangleClass = BuiltClass(binaryName = "Rectangle", bytes = rectangleBytes)
  val measurerClass  = BuiltClass(binaryName = "Measurer",  bytes = measurerBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(shapeClass)
  classes.add(circleClass)
  classes.add(rectangleClass)
  classes.add(measurerClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB58",
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
