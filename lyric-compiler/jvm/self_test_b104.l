//! jvm/self_test_b104.l — Stage B104: lowerMatchUnion pattern-dispatch helper.
//!
//! Builds a Shape union with three cases:
//!   Shape$Circle(radius: int)  — area = radius * radius
//!   Shape$Line(len: int)       — area = len
//!   Shape$Dot                  — area = 0
//!
//! A separate `Shapes` class holds a static `area(Shape) -> int` method
//! generated using lowerMatchUnion.
//!
//! Java output (java -jar):
//!   circle.area=16
//!   line.area=7
//!   dot.area=0
package Jvm.SelfTestB104

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Shape union (abstract base + three case classes) ───────────────────
func makeShapeBytes(): List[List[Byte]] {
  val pool = poolNew()

  val circleFields: List[LField] = newList()
  circleFields.add(LField(flags = ACC_PUBLIC, name = "radius", fieldType = JInt))

  val lineFields: List[LField] = newList()
  lineFields.add(LField(flags = ACC_PUBLIC, name = "len", fieldType = JInt))

  val dotFields: List[LField] = newList()

  val cases: List[LUnionCase] = newList()
  cases.add(LUnionCase(caseName = "Circle", fields = circleFields))
  cases.add(LUnionCase(caseName = "Line", fields = lineFields))
  cases.add(LUnionCase(caseName = "Dot", fields = dotFields))

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

// ── Build Shapes utility class with static area(Shape) -> int ────────────────
func makeShapesBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // arm bodies use slot 1 for the cast value; scrutinee is slot 0
  val circleBody: List[LInsn] = newList()
  circleBody.add(LAload(slot = 1))
  circleBody.add(LGetfield(owner = "Shape$Circle", name = "radius", t = JInt))
  circleBody.add(LDup)
  circleBody.add(LImul)

  val lineBody: List[LInsn] = newList()
  lineBody.add(LAload(slot = 1))
  lineBody.add(LGetfield(owner = "Shape$Line", name = "len", t = JInt))

  val dotBody: List[LInsn] = newList()
  dotBody.add(LIconst(v = 0))

  val arms: List[LMatchArm] = newList()
  arms.add(LMatchArm(caseClass = "Shape$Circle", boundSlot = 1, skipLabel = "skip_circle", bodyInsns = circleBody))
  arms.add(LMatchArm(caseClass = "Shape$Line", boundSlot = 1, skipLabel = "skip_line", bodyInsns = lineBody))
  arms.add(LMatchArm(caseClass = "Shape$Dot", boundSlot = 1, skipLabel = "skip_dot", bodyInsns = dotBody))

  // scrutinee = slot 0; all arms put an int on the stack then goto match_end
  lowerMatchUnion(asm, 0, arms, "match_end")

  // default (no arm matched) → 0
  lowerInsn(LIconst(v = 0), asm)
  lowerInsn(LLabel(name = "match_end"), asm)
  lowerInsn(LIreturn, asm)

  // maxLocals = 2: slot 0 = Shape arg, slot 1 = cast value
  // Use assembleCodeInferred (no StackMapTable); Shapes is emitted as a Java 5
  // (V49) class file via makeClassWithMethodsV49, which avoids the StackMapTable
  // requirement for branches with varying merge-point frames.
  val codeAttr = assembleCodeInferred(asm, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)

  val areaDescPs: List[JvmType] = newList()
  areaDescPs.add(JRef(className = "Shape"))
  val areaMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "area", buildDescriptor(areaDescPs, JInt), attrs)

  val methods: List[MethodInfo] = newList()
  methods.add(areaMethod)
  val cf = makeClassWithMethodsV49("Shapes", methods)
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

  val circleInitIdx = poolMethodref(pool, "Shape$Circle", "<init>", "(I)V")
  val lineInitIdx = poolMethodref(pool, "Shape$Line", "<init>", "(I)V")
  val dotInitIdx = poolMethodref(pool, "Shape$Dot", "<init>", "()V")
  val circleClassIdx = poolClass(pool, "Shape$Circle")
  val lineClassIdx = poolClass(pool, "Shape$Line")
  val dotClassIdx = poolClass(pool, "Shape$Dot")
  val areaIdx = poolMethodref(pool, "Shapes", "area", "(LShape;)I")

  // slot 0: Circle(4), slot 1: Line(7), slot 2: Dot
  emitNew(asm, circleClassIdx)
  emitDup(asm)
  emitPushInt(asm, 4)
  emitInvokespecial(asm, circleInitIdx)
  emitAstore(asm, 0)
  emitNew(asm, lineClassIdx)
  emitDup(asm)
  emitPushInt(asm, 7)
  emitInvokespecial(asm, lineInitIdx)
  emitAstore(asm, 1)
  emitNew(asm, dotClassIdx)
  emitDup(asm)
  emitInvokespecial(asm, dotInitIdx)
  emitAstore(asm, 2)

  // println("circle.area=" + String.valueOf(Shapes.area(circle)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "circle.area=")
  emitAload(asm, 0)
  emitInvokestatic(asm, areaIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("line.area=" + String.valueOf(Shapes.area(line)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "line.area=")
  emitAload(asm, 1)
  emitInvokestatic(asm, areaIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("dot.area=" + String.valueOf(Shapes.area(dot)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "dot.area=")
  emitAload(asm, 2)
  emitInvokestatic(asm, areaIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 3)
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
  val outDir = "/tmp/lyric-jvm-b104"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()

  val shapeBytes = makeShapeBytes()
  val classNames: List[String] = newList()
  classNames.add("Shape")
  classNames.add("Shape$Circle")
  classNames.add("Shape$Line")
  classNames.add("Shape$Dot")
  var i = 0
  while i < shapeBytes.count {
    classes.add(BuiltClass(binaryName = classNames[i], bytes = shapeBytes[i]))
    i = i + 1
  }

  classes.add(BuiltClass(binaryName = "Shapes", bytes = makeShapesBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB104",
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
