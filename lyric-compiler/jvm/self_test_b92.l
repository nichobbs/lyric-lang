//! jvm/self_test_b92.l — Stage B92: lowerUnion smoke test.
//!
//! Builds a Shape union with Circle(radius:int) and Square(side:int) cases
//! via lowerUnion, instantiates both cases from Main, reads their fields.
//!
//! Main prints:
//!   circle.radius=5
//!   square.side=8
package Jvm.SelfTestB92

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeShapeBytes(): List[List[Byte]] {
  val pool = poolNew()

  val circleFields: List[LField] = newList()
  circleFields.add(LField(flags = ACC_PUBLIC, name = "radius", fieldType = JInt))

  val squareFields: List[LField] = newList()
  squareFields.add(LField(flags = ACC_PUBLIC, name = "side", fieldType = JInt))

  val circleCase = LUnionCase(caseName = "Circle", fields = circleFields)
  val squareCase = LUnionCase(caseName = "Square", fields = squareFields)
  val cases: List[LUnionCase] = newList()
  cases.add(circleCase)
  cases.add(squareCase)

  val baseMethods: List[LFunc] = newList()
  val u = LUnion(baseName = "Shape", cases = cases, methods = baseMethods)

  val classFiles = lowerUnion(u, pool)

  val result: List[List[Byte]] = newList()
  var i = 0
  while i < classFiles.count {
    result.add(serializeClassWithPool(classFiles[i], pool))
    i = i + 1
  }
  result
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  val circleInitIdx = poolMethodref(pool, "Shape$Circle", "<init>", "(I)V")
  val squareInitIdx = poolMethodref(pool, "Shape$Square", "<init>", "(I)V")
  val radiusIdx = poolFieldref(pool, "Shape$Circle", "radius", "I")
  val sideIdx = poolFieldref(pool, "Shape$Square", "side", "I")
  val circleClassIdx = poolClass(pool, "Shape$Circle")
  val squareClassIdx = poolClass(pool, "Shape$Square")

  // Shape$Circle c = new Shape$Circle(5);  [slot 0]
  emitNew(asm, circleClassIdx)
  emitDup(asm)
  emitPushInt(asm, 5)
  emitInvokespecial(asm, circleInitIdx)
  emitAstore(asm, 0)

  // Shape$Square s = new Shape$Square(8);  [slot 1]
  emitNew(asm, squareClassIdx)
  emitDup(asm)
  emitPushInt(asm, 8)
  emitInvokespecial(asm, squareInitIdx)
  emitAstore(asm, 1)

  // System.out.println("circle.radius=" + String.valueOf(c.radius))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "circle.radius=")
  emitAload(asm, 0)
  emitGetfield(asm, radiusIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("square.side=" + String.valueOf(s.side))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "square.side=")
  emitAload(asm, 1)
  emitGetfield(asm, sideIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b92"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val shapeBytes = makeShapeBytes()
  // lowerUnion returns [base, case0, case1]: Shape, Shape$Circle, Shape$Square
  val shapeClass = BuiltClass(binaryName = "Shape", bytes = shapeBytes[0])
  val circleClass = BuiltClass(binaryName = "Shape$Circle", bytes = shapeBytes[1])
  val squareClass = BuiltClass(binaryName = "Shape$Square", bytes = shapeBytes[2])
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())

  val classes: List[BuiltClass] = newList()
  classes.add(shapeClass)
  classes.add(circleClass)
  classes.add(squareClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB92",
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
