//! jvm/self_test_b99.l — Stage B99: reference arrays (LAnewarray/LAaload/LAastore/LArraylength).
//!
//! Adds LAnewarray/LNewarray/LArraylength/LIaload/LLaload/LFaload/LDaload/
//! LAaload/LBaload/LCaload/LSaload/LIastore/LLastore/LFastore/LDastore/
//! LAastore/LBastore/LCastore/LSastore to the LInsn union.
//!
//! Creates a StringUtils class via lowerFunc with a `join(String[], String): String`
//! method that iterates over the array, concatenating elements with a separator.
//!
//! Also creates an int array test via LNewarray / LIaload / LIastore: sumArray(int[]).
//!
//! Java output (java -jar):
//!   join=a,b,c
//!   sum=6
package Jvm.SelfTestB99

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeJoinMethod(): LFunc {
  // join(String[] arr, String sep): String
  //   slot 0 = arr  (Object[])
  //   slot 1 = sep  (String)
  //   slot 2 = result (String, mutable)
  //   slot 3 = i (int counter)
  //
  // result = ""
  // i = 0
  // [loop]: if i >= arr.length goto done
  //         if i == 0 goto no_sep
  //         result = result.concat(sep)
  //         [no_sep]: result = result.concat(arr[i])
  //         i = i + 1
  //         goto loop
  // [done]: return result
  val insns: List[LInsn] = newList()

  insns.add(LPushString(s = ""))
  insns.add(LAstoreAs(slot = 2, className = "java/lang/String"))
  // result = ""
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = 3))
  // i = 0

  insns.add(LLabel(name = "loop"))
  // <- branch target
  insns.add(LIload(slot = 3))
  // i
  insns.add(LAload(slot = 0))
  // arr
  insns.add(LArraylength)
  // arr.length
  insns.add(LIfIcmpge(label = "done"))
  // if i >= arr.length goto done

  insns.add(LIload(slot = 3))
  // i
  insns.add(LIfeq(label = "no_sep"))
  // if i == 0, skip sep

  // result = result.concat(sep)
  insns.add(LAload(slot = 2))
  insns.add(LAload(slot = 1))
  val concatPsSep: List[JvmType] = newList()
  concatPsSep.add(JRef(className = "java/lang/String"))
  insns.add(
    LInvokevirtual(
      owner = "java/lang/String",
      name = "concat",
      params = concatPsSep,
      ret = JRef(className = "java/lang/String")
    )
  )
  insns.add(LAstore(slot = 2))

  insns.add(LLabel(name = "no_sep"))
  // <- branch target
  // result = result.concat(arr[i])
  insns.add(LAload(slot = 2))
  insns.add(LAload(slot = 0))
  // arr
  insns.add(LIload(slot = 3))
  // i
  insns.add(LAaload)
  // arr[i]
  val concatPsElem: List[JvmType] = newList()
  concatPsElem.add(JRef(className = "java/lang/String"))
  insns.add(
    LInvokevirtual(
      owner = "java/lang/String",
      name = "concat",
      params = concatPsElem,
      ret = JRef(className = "java/lang/String")
    )
  )
  insns.add(LAstore(slot = 2))

  insns.add(LIinc(slot = 3, delta = 1))
  // i++
  insns.add(LGoto(label = "loop"))

  insns.add(LLabel(name = "done"))
  // <- branch target
  insns.add(LAload(slot = 2))
  insns.add(LAreturn)

  val params: List[JvmType] = newList()
  params.add(JArray(elem = JRef(className = "java/lang/String")))
  params.add(JRef(className = "java/lang/String"))
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "join",
    params = params,
    ret = JRef(className = "java/lang/String"),
    insns = insns,
    maxStack = 3,
    maxLocals = 4
  )
}

func makeSumArrayMethod(): LFunc {
  // sumArray(int[] arr): int
  //   slot 0 = arr
  //   slot 1 = sum
  //   slot 2 = i
  val insns: List[LInsn] = newList()
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = 1))
  // sum = 0
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = 2))
  // i = 0
  insns.add(LLabel(name = "loop2"))
  insns.add(LIload(slot = 2))
  insns.add(LAload(slot = 0))
  insns.add(LArraylength)
  insns.add(LIfIcmpge(label = "done2"))
  // if i >= arr.length goto done
  insns.add(LIload(slot = 1))
  // sum
  insns.add(LAload(slot = 0))
  // arr
  insns.add(LIload(slot = 2))
  // i
  insns.add(LIaload)
  // arr[i]
  insns.add(LIadd)
  // sum + arr[i]
  insns.add(LIstore(slot = 1))
  // sum = ...
  insns.add(LIinc(slot = 2, delta = 1))
  // i++
  insns.add(LGoto(label = "loop2"))
  insns.add(LLabel(name = "done2"))
  insns.add(LIload(slot = 1))
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JArray(elem = JInt))
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "sumArray",
    params = params,
    ret = JInt,
    insns = insns,
    maxStack = 3,
    maxLocals = 3
  )
}

func makeStringUtilsBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(makeJoinMethod(), pool))
  methods.add(lowerFunc(makeSumArrayMethod(), pool))
  val cf = makeClassWithMethods("StringUtils", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valOfIIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val joinIdx = poolMethodref(pool, "StringUtils", "join", "([Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val sumArrIdx = poolMethodref(pool, "StringUtils", "sumArray", "([I)I")
  val strArrClass = poolClass(pool, "java/lang/String")

  // Build String[] {"a", "b", "c"}
  // anewarray java/lang/String, size=3
  // dup; iconst_0; ldc "a"; aastore
  // dup; iconst_1; ldc "b"; aastore
  // dup; iconst_2; ldc "c"; aastore
  // => arr ref on stack
  emitPushInt(asm, 3)
  emitAnewarray(asm, strArrClass)
  emitDup(asm)
  emitPushInt(asm, 0)
  emitPushString(asm, "a")
  emitAastore(asm)
  emitDup(asm)
  emitPushInt(asm, 1)
  emitPushString(asm, "b")
  emitAastore(asm)
  emitDup(asm)
  emitPushInt(asm, 2)
  emitPushString(asm, "c")
  emitAastore(asm)
  emitAstore(asm, 1)
  // store arr -> slot 1

  // println("join=" + StringUtils.join(arr, ","))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "join=")
  emitAload(asm, 1)
  emitPushString(asm, ",")
  emitInvokestatic(asm, joinIdx)
  val concatPoolIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  emitInvokevirtual(asm, concatPoolIdx)
  emitInvokevirtual(asm, printlnIdx)

  // Build int[] {1, 2, 3}
  emitPushInt(asm, 3)
  emitNewarray(asm, T_INT)
  emitDup(asm)
  emitPushInt(asm, 0)
  emitPushInt(asm, 1)
  emitIastore(asm)
  emitDup(asm)
  emitPushInt(asm, 1)
  emitPushInt(asm, 2)
  emitIastore(asm)
  emitDup(asm)
  emitPushInt(asm, 2)
  emitPushInt(asm, 3)
  emitIastore(asm)
  emitAstore(asm, 2)
  // store int[] -> slot 2

  // println("sum=" + String.valueOf(StringUtils.sumArray(intArr)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "sum=")
  emitAload(asm, 2)
  emitInvokestatic(asm, sumArrIdx)
  emitInvokestatic(asm, valOfIIdx)
  emitInvokevirtual(asm, concatPoolIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 3)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b99"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val utilsClass = BuiltClass(binaryName = "StringUtils", bytes = makeStringUtilsBytes())
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(utilsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB99",
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
