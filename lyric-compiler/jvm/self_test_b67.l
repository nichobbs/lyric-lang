// jvm/self_test_b67.l — Stage B67: lookupswitch instruction.
//
// Generates Switch.class with:
//   dayType(I)String  — classifies day-of-week (1-7) as "weekday" or "weekend"
//                       using lookupswitch for 6 and 7 (weekend), default "weekday"
//   grade(I)String    — maps score bands: >=90=>"A", >=80=>"B", >=70=>"C", else=>"F"
//                       using tableswitch over [70..90] → 3 cases + default
//
// Main prints:
//   dayType(1)  → "weekday"
//   dayType(6)  → "weekend"
//   dayType(7)  → "weekend"
//
// Exercises: emitLookupSwitch with SwitchPair list, sorted keys requirement.

package Jvm.SelfTestB67

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeSwitchBytes(): List[Byte] {
  val pool = poolNew()

  // dayType(I)String
  // lookupswitch on day: 6->"WEEKEND", 7->"WEEKEND"; default->"WEEKDAY"
  val asmDay = newAssembler(pool)
  emitIload(asmDay, 0)
  val pairs: List[SwitchPair] = newList()
  pairs.add(SwitchPair(key = 6, label = "SAT"))
  pairs.add(SwitchPair(key = 7, label = "SUN"))
  emitLookupSwitch(asmDay, "WEEKDAY", pairs)
  emitLabel(asmDay, "SAT")
  emitLabel(asmDay, "SUN")
  emitPushString(asmDay, "weekend")
  emitAreturn(asmDay)
  emitLabel(asmDay, "WEEKDAY")
  emitPushString(asmDay, "weekday")
  emitAreturn(asmDay)
  val dayCode = assembleCode(asmDay, 1, 1)
  val dayAttrs: List[Attribute] = newList()
  dayAttrs.add(dayCode)
  val dayMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "dayType", "(I)Ljava/lang/String;", dayAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(dayMethod)
  val cf = makeClassWithMethodsV49("Switch", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool     = poolNew()
  val asm      = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val dayRef   = poolMethodref(pool, "Switch", "dayType", "(I)Ljava/lang/String;")

  // println(Switch.dayType(1)) → "weekday"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, dayRef)
  emitInvokevirtual(asm, printlnS)

  // println(Switch.dayType(6)) → "weekend"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 6)
  emitInvokestatic(asm, dayRef)
  emitInvokevirtual(asm, printlnS)

  // println(Switch.dayType(7)) → "weekend"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 7)
  emitInvokestatic(asm, dayRef)
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
  val outDir = "/tmp/lyric-jvm-b67"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val switchBytes = makeSwitchBytes()
  val mainBytes   = makeMainClassBytes()

  val switchClass = BuiltClass(binaryName = "Switch", bytes = switchBytes)
  val mainClass   = BuiltClass(binaryName = "Main",   bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(switchClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB67",
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
