// jvm/self_test_b103.l — Stage B103: maxStack/maxLocals inference.
//
// Identical to self_test_b102 except maxStack = 0 and maxLocals = 0 on
// both LFunc values.  lowerFunc must infer the correct values automatically.
//
// Java output (java -jar):
//   A=gradeStr(4)
//   B=gradeStr(3)
//   C=gradeStr(2)
//   ?=gradeStr(5)
//   Mon=dayName(1)
//   Wed=dayName(3)
//   ?=dayName(2)

package Jvm.SelfTestB103

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeGradeStrMethod(): LFunc {
  // gradeStr(int score): String  — score in 0..4
  // tableswitch low=0 high=4:
  //   0 -> "F", 1 -> "D", 2 -> "C", 3 -> "B", 4 -> "A"
  //   default -> "?"
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))

  val cases: List[String] = newList()
  cases.add("case_f")
  cases.add("case_d")
  cases.add("case_c")
  cases.add("case_b")
  cases.add("case_a")
  insns.add(LTableswitch(low = 0, high = 4, defaultLabel = "case_q", caseLabels = cases))

  insns.add(LLabel(name = "case_f"))
  insns.add(LPushString(s = "F"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "case_d"))
  insns.add(LPushString(s = "D"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "case_c"))
  insns.add(LPushString(s = "C"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "case_b"))
  insns.add(LPushString(s = "B"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "case_a"))
  insns.add(LPushString(s = "A"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "case_q"))
  insns.add(LPushString(s = "?"))
  insns.add(LAreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "gradeStr",
    params    = params,
    ret       = JRef(className = "java/lang/String"),
    insns     = insns,
    maxStack  = 0,
    maxLocals = 0
  )
}

func makeDayNameMethod(): LFunc {
  // dayName(int d): String  — sparse keys 1=Mon,3=Wed,5=Fri,7=Sun
  // lookupswitch with 4 pairs
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))

  val dayPairs: List[SwitchPair] = newList()
  dayPairs.add(SwitchPair(key = 1, label = "day_mon"))
  dayPairs.add(SwitchPair(key = 3, label = "day_wed"))
  dayPairs.add(SwitchPair(key = 5, label = "day_fri"))
  dayPairs.add(SwitchPair(key = 7, label = "day_sun"))
  insns.add(LLookupswitch(defaultLabel = "day_q", pairs = dayPairs))

  insns.add(LLabel(name = "day_mon"))
  insns.add(LPushString(s = "Mon"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "day_wed"))
  insns.add(LPushString(s = "Wed"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "day_fri"))
  insns.add(LPushString(s = "Fri"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "day_sun"))
  insns.add(LPushString(s = "Sun"))
  insns.add(LAreturn)
  insns.add(LLabel(name = "day_q"))
  insns.add(LPushString(s = "?"))
  insns.add(LAreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "dayName",
    params    = params,
    ret       = JRef(className = "java/lang/String"),
    insns     = insns,
    maxStack  = 0,
    maxLocals = 0
  )
}

func makeSwitchBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(makeGradeStrMethod(), pool))
  methods.add(lowerFunc(makeDayNameMethod(), pool))
  val cf = makeClassWithMethods("Switch", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx   = poolFieldref(pool,  "java/lang/System",    "out",      "Ljava/io/PrintStream;")
  val printlnIdx  = poolMethodref(pool, "java/io/PrintStream", "println",  "(Ljava/lang/String;)V")
  val concatIdx   = poolMethodref(pool, "java/lang/String",    "concat",   "(Ljava/lang/String;)Ljava/lang/String;")
  val gradeStrIdx = poolMethodref(pool, "Switch",              "gradeStr", "(I)Ljava/lang/String;")
  val dayNameIdx  = poolMethodref(pool, "Switch",              "dayName",  "(I)Ljava/lang/String;")

  // println(Switch.gradeStr(4) + "=gradeStr(4)")
  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 4)
  emitInvokestatic(asm, gradeStrIdx)
  emitPushString(asm, "=gradeStr(4)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, gradeStrIdx)
  emitPushString(asm, "=gradeStr(3)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, gradeStrIdx)
  emitPushString(asm, "=gradeStr(2)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, gradeStrIdx)
  emitPushString(asm, "=gradeStr(5)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, dayNameIdx)
  emitPushString(asm, "=dayName(1)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, dayNameIdx)
  emitPushString(asm, "=dayName(3)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitGetstatic(asm, sysOutIdx)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, dayNameIdx)
  emitPushString(asm, "=dayName(2)")
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b103"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val switchClass = BuiltClass(binaryName = "Switch", bytes = makeSwitchBytes())
  val mainClass   = BuiltClass(binaryName = "Main",   bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(switchClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB103",
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
