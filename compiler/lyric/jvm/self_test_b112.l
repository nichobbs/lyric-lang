// jvm/self_test_b112.l — Stage B112: lowerEnum (JVM enum class codegen).
//
// Creates a JVM enum `Direction` with four variants: North, South, East, West.
//
// A Main class calls Direction.values() and prints name() for each.
//
// Java output (java -jar):
//   North
//   South
//   East
//   West

package Jvm.SelfTestB112

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Direction enum ──────────────────────────────────────────────────────

func makeDirectionBytes(pool: in Pool): List[Byte] {
  val variants: List[String] = newList()
  variants.add("North")
  variants.add("South")
  variants.add("East")
  variants.add("West")
  val e = LEnumType(className = "Direction", variants = variants)
  val cf = lowerEnum(e, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val valuesRef  = poolMethodref(pool, "Direction", "values", "()[LDirection;")
  val lengthRef  = poolMethodref(pool, "Direction", "name",   "()Ljava/lang/String;")
  val arrLenOp   = poolClass(pool, "Direction")

  // Direction[] dirs = Direction.values()
  emitInvokestatic(asm, valuesRef)
  emitAstore(asm, 1)       // slot 1 = dirs

  // int i = 0
  emitIconst(asm, 0)
  emitIstore(asm, 2)       // slot 2 = i

  // while (i < dirs.length) { println(dirs[i].name()); i++ }
  emitLabel(asm, "loop_start")
  emitIload(asm, 2)
  emitAload(asm, 1)
  emitArraylength(asm)
  emitIfIcmpge(asm, "loop_end")

  emitGetstatic(asm, sysOutIdx)
  emitAload(asm, 1)
  emitIload(asm, 2)
  emitAaload(asm)
  emitInvokevirtual(asm, lengthRef)    // Direction.name() inherited from Enum
  emitInvokevirtual(asm, printlnIdx)

  emitIinc(asm, 2, 1)
  emitGoto(asm, "loop_start")

  emitLabel(asm, "loop_end")
  emitReturn(asm)

  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VObject("[Ljava/lang/String;"))
  frameLocals.add(VObject("[LDirection;"))
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 4, 3, frameLocals)
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
  val outDir = "/tmp/lyric-jvm-b112"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Direction", bytes = makeDirectionBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main",      bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB112",
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
