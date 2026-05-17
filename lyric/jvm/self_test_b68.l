// jvm/self_test_b68.l — Stage B68: tableswitch instruction.
//
// Generates Grades.class with:
//   letterGrade(I)String  — maps score/10 to letter: 10,9->"A", 8->"B", 7->"C", else->"F"
//                           using tableswitch over [7..10]
//
// Main prints:
//   letterGrade(95) → "A"   (95/10 = 9 → case 9)
//   letterGrade(100)→ "A"   (100/10 = 10 → case 10)
//   letterGrade(83) → "B"   (83/10 = 8 → case 8)
//   letterGrade(72) → "C"   (72/10 = 7 → case 7)
//   letterGrade(60) → "F"   (60/10 = 6 → default)
//
// Exercises: emitTableSwitch with contiguous case range and shared labels.

package Jvm.SelfTestB68

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeGradesBytes(): List[Byte] {
  val pool = poolNew()

  // letterGrade(I)String
  // score/10 → tableswitch [7..10]
  val asmGrade = newAssembler(pool)
  emitIload(asmGrade, 0)
  emitPushInt(asmGrade, 10)
  emitIdiv(asmGrade)
  val caseLabels: List[String] = newList()
  caseLabels.add("GRADE_C")    // 7
  caseLabels.add("GRADE_B")    // 8
  caseLabels.add("GRADE_A")    // 9
  caseLabels.add("GRADE_A")    // 10
  emitTableSwitch(asmGrade, 7, 10, "GRADE_F", caseLabels)
  emitLabel(asmGrade, "GRADE_A")
  emitPushString(asmGrade, "A")
  emitAreturn(asmGrade)
  emitLabel(asmGrade, "GRADE_B")
  emitPushString(asmGrade, "B")
  emitAreturn(asmGrade)
  emitLabel(asmGrade, "GRADE_C")
  emitPushString(asmGrade, "C")
  emitAreturn(asmGrade)
  emitLabel(asmGrade, "GRADE_F")
  emitPushString(asmGrade, "F")
  emitAreturn(asmGrade)
  val gradeCode = assembleCode(asmGrade, 2, 1)
  val gradeAttrs: List[Attribute] = newList()
  gradeAttrs.add(gradeCode)
  val gradeMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "letterGrade", "(I)Ljava/lang/String;", gradeAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(gradeMethod)
  val cf = makeClassWithMethodsV49("Grades", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val gradeRef  = poolMethodref(pool, "Grades", "letterGrade", "(I)Ljava/lang/String;")

  // println(Grades.letterGrade(95)) → "A"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 95)
  emitInvokestatic(asm, gradeRef)
  emitInvokevirtual(asm, printlnS)

  // println(Grades.letterGrade(100)) → "A"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 100)
  emitInvokestatic(asm, gradeRef)
  emitInvokevirtual(asm, printlnS)

  // println(Grades.letterGrade(83)) → "B"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 83)
  emitInvokestatic(asm, gradeRef)
  emitInvokevirtual(asm, printlnS)

  // println(Grades.letterGrade(72)) → "C"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 72)
  emitInvokestatic(asm, gradeRef)
  emitInvokevirtual(asm, printlnS)

  // println(Grades.letterGrade(60)) → "F"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 60)
  emitInvokestatic(asm, gradeRef)
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
  val outDir = "/tmp/lyric-jvm-b68"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val gradesBytes = makeGradesBytes()
  val mainBytes   = makeMainClassBytes()

  val gradesClass = BuiltClass(binaryName = "Grades", bytes = gradesBytes)
  val mainClass   = BuiltClass(binaryName = "Main",   bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(gradesClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB68",
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
