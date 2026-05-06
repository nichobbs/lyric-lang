// jvm/self_test_b86.l — Stage B86: interface with default method.
//
// Generates:
//   Greeter.class  — interface:
//       abstract greet()String
//       default  greetLoud()String — returns this.greet().toUpperCase()
//   HelloGreeter.class — implements Greeter:
//       <init>()V, greet()String → "hello"
//
// Main prints:
//   hello
//   HELLO
//
// Exercises: ACC_INTERFACE + ACC_ABSTRACT flags, abstract method (no Code attr),
//            default interface method with Code, invokeinterface, interface
//            constant pool entry, ClassFile.interfaces list.

package Jvm.SelfTestB86

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeGreeterInterfaceBytes(): List[Byte] {
  val pool = poolNew()

  // Abstract method: greet()String — no Code attribute
  val greetAttrs: List[Attribute] = newList()
  val greetMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "greet",
    "()Ljava/lang/String;", greetAttrs)

  // Default method: greetLoud()String
  // aload_0; invokeinterface Greeter.greet ()Ljava/lang/String; 1
  // invokevirtual String.toUpperCase ()Ljava/lang/String;
  // areturn
  val greetRef   = poolIfaceMethodref(pool, "Greeter", "greet", "()Ljava/lang/String;")
  val toUpperRef = poolMethodref(pool, "java/lang/String", "toUpperCase", "()Ljava/lang/String;")
  val asmGL = newAssembler(pool)
  emitAload(asmGL, 0)
  emitInvokeinterface(asmGL, greetRef, 1)
  emitInvokevirtual(asmGL, toUpperRef)
  emitAreturn(asmGL)
  val glCode = assembleCode(asmGL, 1, 1)
  val glAttrs: List[Attribute] = newList()
  glAttrs.add(glCode)
  val greetLoudMethod = makeMethodInfo(ACC_PUBLIC, "greetLoud",
    "()Ljava/lang/String;", glAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(greetMethod)
  methods.add(greetLoudMethod)

  val cf = makeInterfaceWithMethods("Greeter", methods)
  serializeClassWithPool(cf, pool)
}

func makeHelloGreeterBytes(): List[Byte] {
  val pool = poolNew()

  // Constructor <init>()V — calls Object.<init>()
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // greet()String — returns "hello"
  val asmG = newAssembler(pool)
  emitPushString(asmG, "hello")
  emitAreturn(asmG)
  val gCode = assembleCode(asmG, 1, 1)
  val gAttrs: List[Attribute] = newList()
  gAttrs.add(gCode)
  val gMethod = makeMethodInfo(ACC_PUBLIC, "greet", "()Ljava/lang/String;", gAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(gMethod)

  val ifaces: List[String] = newList()
  ifaces.add("Greeter")
  val cf = makeClassWithInterfaces("HelloGreeter", ifaces, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut      = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS    = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val hgClass     = poolClass(pool, "HelloGreeter")
  val hgInit      = poolMethodref(pool, "HelloGreeter", "<init>", "()V")
  val greetRef    = poolIfaceMethodref(pool, "Greeter", "greet",     "()Ljava/lang/String;")
  val greetLRef   = poolIfaceMethodref(pool, "Greeter", "greetLoud", "()Ljava/lang/String;")

  // HelloGreeter g = new HelloGreeter()  slot 0
  emitNew(asm, hgClass)
  emitDup(asm)
  emitInvokespecial(asm, hgInit)
  emitAstore(asm, 0)

  // println(g.greet())
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokeinterface(asm, greetRef, 1)
  emitInvokevirtual(asm, printlnS)

  // println(g.greetLoud())
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokeinterface(asm, greetLRef, 1)
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
  val outDir = "/tmp/lyric-jvm-b86"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val greeterBytes     = makeGreeterInterfaceBytes()
  val helloGreeterBytes = makeHelloGreeterBytes()
  val mainBytes        = makeMainClassBytes()

  val greeterClass      = BuiltClass(binaryName = "Greeter",      bytes = greeterBytes)
  val helloGreeterClass = BuiltClass(binaryName = "HelloGreeter", bytes = helloGreeterBytes)
  val mainClass         = BuiltClass(binaryName = "Main",         bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(greeterClass)
  classes.add(helloGreeterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB86",
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
