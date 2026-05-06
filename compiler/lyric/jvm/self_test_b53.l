// jvm/self_test_b53.l — Stage B53: recursive static method (factorial).
//
// Generates Factorial.class (Java 5 / major=49) with:
//   fact(I)I — recursive: if n==0 return 1, else return n * fact(n-1)
//
// Main prints:
//   fact(0) → 1
//   fact(5) → 120
//
// Exercises: ifeq branch to base case, recursive invokestatic call,
//            imul for accumulation.  Java 5 major=49 avoids StackMapTable
//            requirement for the branch target.

package Jvm.SelfTestB53

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeFactorialClassBytes(): List[Byte] {
  val pool    = poolNew()
  val factRef = poolMethodref(pool, "Factorial", "fact", "(I)I")

  // ── fact(I)I ─────────────────────────────────────────────────────────────────
  // if n==0 jump to DONE
  // n * fact(n-1); ireturn
  // DONE: iconst_1; ireturn
  val asm = newAssembler(pool)
  emitIload(asm, 0)
  emitIfeq(asm, "DONE")
  emitIload(asm, 0)
  emitIload(asm, 0)
  emitIconst(asm, 1)
  emitIsub(asm)
  emitInvokestatic(asm, factRef)
  emitImul(asm)
  emitIreturn(asm)
  emitLabel(asm, "DONE")
  emitIconst(asm, 1)
  emitIreturn(asm)

  // maxStack: iload_0[1] + iload_0[2] + iconst_1[3] → isub[2] → invokestatic→[2] → imul[1]
  val factCode = assembleCode(asm, 3, 1)
  val factAttrs: List[Attribute] = newList()
  factAttrs.add(factCode)
  val factMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "fact", "(I)I", factAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(factMethod)
  val cf = makeClassWithMethodsV49("Factorial", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val factRef  = poolMethodref(pool, "Factorial", "fact", "(I)I")

  // println(Factorial.fact(0))  → 1
  emitGetstatic(asm, sysOut)
  emitIconst(asm, 0)
  emitInvokestatic(asm, factRef)
  emitInvokevirtual(asm, printlnI)

  // println(Factorial.fact(5))  → 120
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, factRef)
  emitInvokevirtual(asm, printlnI)

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
  val outDir = "/tmp/lyric-jvm-b53"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val factBytes = makeFactorialClassBytes()
  val mainBytes = makeMainClassBytes()

  val factClass = BuiltClass(binaryName = "Factorial", bytes = factBytes)
  val mainClass = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(factClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB53",
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
