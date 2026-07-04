//! jvm/self_test_b94.l — Stage B94: lowerWire smoke test.
//!
//! Builds a Config wire with a single `answer: int = 42` binding via lowerWire.
//! Main calls Config.bootstrap(), then Config.answer(), and prints the result.
//!
//! Main prints:
//!   answer=42
package Jvm.SelfTestB94

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeConfigBytes(): List[Byte] {
  val pool = poolNew()

  // Binding: answer = 42 (push 42; lowerWire appends putstatic)
  val answerInsns: List[LInsn] = newList()
  answerInsns.add(LIconst(v = 42))
  val binding = LWireBinding(name = "answer", valType = JInt, insns = answerInsns, tempSlots = 0)

  val bindings: List[LWireBinding] = newList()
  bindings.add(binding)

  val exposes: List[String] = newList()
  exposes.add("answer")

  val w = LWire(className = "Config", providedParams = newList(), bindings = bindings, exposes = exposes)
  val cf = lowerWire(w, pool)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val bsIdx = poolMethodref(pool, "Config", "bootstrap", "()V")
  val answerIdx = poolMethodref(pool, "Config", "answer", "()I")

  // Config.bootstrap()
  emitInvokestatic(asm, bsIdx)

  // System.out.println("answer=" + String.valueOf(Config.answer()))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "answer=")
  emitInvokestatic(asm, answerIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b94"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val configClass = BuiltClass(binaryName = "Config", bytes = makeConfigBytes())
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(configClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB94",
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
