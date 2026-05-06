// jvm/self_test_b41.l — Stage B41: String.equals and conditional string routing.
//
// Generates Greeter.class with:
//   greet(Ljava/lang/String;)Ljava/lang/String;
//       — if s.equals("Alice") return "Hello, Alice!"
//         else return "Hello, stranger!"
//
// Uses: aload_0; ldc "Alice"; invokevirtual String.equals; ifeq → else branch;
//       ldc "Hello, Alice!"; areturn; else: ldc "Hello, stranger!"; areturn
//
// Main:
//   greet("Alice")   → "Hello, Alice!"
//   greet("Bob")     → "Hello, stranger!"
//
// Expected output:
//   Hello, Alice!
//   Hello, stranger!
//
// Exercises: invokevirtual String.equals(Object)Z, ifeq branch,
// assembleCodeWithFrames with VObject frame for String parameter.

package Jvm.SelfTestB41

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeGreeterClassBytes(): List[Byte] {
  val pool = poolNew()

  val equalsRef = poolMethodref(pool, "java/lang/String", "equals", "(Ljava/lang/Object;)Z")

  // ── greet(Ljava/lang/String;)Ljava/lang/String; ───────────────────────────────
  // aload_0; ldc "Alice"; invokevirtual equals; ifeq lbl_else
  // ldc "Hello, Alice!"; areturn
  // lbl_else: ldc "Hello, stranger!"; areturn
  val asmG = newAssembler(pool)

  emitAload(asmG, 0)
  emitPushString(asmG, "Alice")
  emitInvokevirtual(asmG, equalsRef)
  emitIfeq(asmG, "lbl_else")
  emitPushString(asmG, "Hello, Alice!")
  emitAreturn(asmG)
  emitLabel(asmG, "lbl_else")
  emitPushString(asmG, "Hello, stranger!")
  emitAreturn(asmG)

  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VObject(className = "java/lang/String"))
  val gCode = assembleCodeWithFrames(asmG, 2, 1, frameLocals)
  val gAttrs: List[Attribute] = newList()
  gAttrs.add(gCode)
  val greetMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "greet",
    "(Ljava/lang/String;)Ljava/lang/String;",
    gAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(greetMethod)
  val cf = makeClassWithMethods("Greeter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val greetRef = poolMethodref(pool, "Greeter", "greet", "(Ljava/lang/String;)Ljava/lang/String;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // greet("Alice") → "Hello, Alice!"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Alice")
  emitInvokestatic(asm, greetRef)
  emitInvokevirtual(asm, printlnS)

  // greet("Bob") → "Hello, stranger!"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Bob")
  emitInvokestatic(asm, greetRef)
  emitInvokevirtual(asm, printlnS)

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
  val outDir = "/tmp/lyric-jvm-b41"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val greeterBytes = makeGreeterClassBytes()
  val mainBytes    = makeMainClassBytes()

  val greeterClass = BuiltClass(binaryName = "Greeter", bytes = greeterBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(greeterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB41",
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
