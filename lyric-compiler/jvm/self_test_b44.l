//! jvm/self_test_b44.l — Stage B44: inheritance with virtual dispatch.
//!
//! Generates three class files:
//!   Animal.class — abstract class with abstract speak()Ljava/lang/String;
//!   Dog.class    — extends Animal; speak() returns "Woof!"
//!   Cat.class    — extends Animal; speak() returns "Meow!"
//!   Main.class   — creates Dog and Cat, calls speak() via invokevirtual Animal.speak
//!
//! Expected output:
//!   Woof!
//!   Meow!
//!
//! Exercises: makeAbstractClass, makeCaseClass (non-Object superClass),
//!            invokespecial on superclass <init>, invokevirtual through abstract type.
package Jvm.SelfTestB44

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeAnimalBytes(): List[Byte] {
  val pool = poolNew()
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")

  // <init>()V — calls Object.<init>
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // abstract speak()Ljava/lang/String; — no Code attribute
  val noAttrs: List[Attribute] = newList()
  val speakMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "speak", "()Ljava/lang/String;", noAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(speakMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeAbstractClass("Animal", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeDogBytes(): List[Byte] {
  val pool = poolNew()
  val animalInit = poolMethodref(pool, "Animal", "<init>", "()V")

  // <init>()V — calls Animal.<init>
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, animalInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // speak()Ljava/lang/String; — returns "Woof!"
  val asmSpeak = newAssembler(pool)
  emitPushString(asmSpeak, "Woof!")
  emitAreturn(asmSpeak)
  val speakCode = assembleCode(asmSpeak, 1, 1)
  val speakAttrs: List[Attribute] = newList()
  speakAttrs.add(speakCode)
  val speakMethod = makeMethodInfo(ACC_PUBLIC, "speak", "()Ljava/lang/String;", speakAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(speakMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeCaseClass("Dog", "Animal", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeCatBytes(): List[Byte] {
  val pool = poolNew()
  val animalInit = poolMethodref(pool, "Animal", "<init>", "()V")

  // <init>()V — calls Animal.<init>
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, animalInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // speak()Ljava/lang/String; — returns "Meow!"
  val asmSpeak = newAssembler(pool)
  emitPushString(asmSpeak, "Meow!")
  emitAreturn(asmSpeak)
  val speakCode = assembleCode(asmSpeak, 1, 1)
  val speakAttrs: List[Attribute] = newList()
  speakAttrs.add(speakCode)
  val speakMethod = makeMethodInfo(ACC_PUBLIC, "speak", "()Ljava/lang/String;", speakAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(speakMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeCaseClass("Cat", "Animal", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val animalSpeak = poolMethodref(pool, "Animal", "speak", "()Ljava/lang/String;")
  val dogClass = poolClass(pool, "Dog")
  val dogInit = poolMethodref(pool, "Dog", "<init>", "()V")
  val catClass = poolClass(pool, "Cat")
  val catInit = poolMethodref(pool, "Cat", "<init>", "()V")

  // println(new Dog().speak())  → "Woof!"
  emitGetstatic(asm, sysOut)
  emitNew(asm, dogClass)
  emitDup(asm)
  emitInvokespecial(asm, dogInit)
  emitInvokevirtual(asm, animalSpeak)
  emitInvokevirtual(asm, println_)

  // println(new Cat().speak())  → "Meow!"
  emitGetstatic(asm, sysOut)
  emitNew(asm, catClass)
  emitDup(asm)
  emitInvokespecial(asm, catInit)
  emitInvokevirtual(asm, animalSpeak)
  emitInvokevirtual(asm, println_)

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
  val outDir = "/tmp/lyric-jvm-b44"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val animalBytes = makeAnimalBytes()
  val dogBytes = makeDogBytes()
  val catBytes = makeCatBytes()
  val mainBytes = makeMainClassBytes()

  val animalClass = BuiltClass(binaryName = "Animal", bytes = animalBytes)
  val dogClass = BuiltClass(binaryName = "Dog", bytes = dogBytes)
  val catClass = BuiltClass(binaryName = "Cat", bytes = catBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(animalClass)
  classes.add(dogClass)
  classes.add(catClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB44",
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
