//! jvm/fuzzer.l — Stage B8: differential fuzzing corpus.
//!
//! Generates a fixed set of LFunc method shapes that stress the JVM verifier
//! across different opcodes, branching patterns, return types, and local
//! variable configurations.  All methods are intended for a single class
//! `B8Corpus` as public static members.
//!
//! The corpus covers:
//!   voidNoop     — void method, just returns
//!   constFortyTwo — returns int constant 42
//!   intAdd       — adds two int params
//!   intSub       — subtracts two int params
//!   intMul       — multiplies two int params
//!   intNeg       — negates one int param
//!   intMax       — if/else branch (max of two ints); requires StackMapTable
//!   intAbs       — if/else branch (absolute value); requires StackMapTable
//!   intLoop      — while loop (sum 1..n); requires StackMapTable
//!   longAdd      — adds two long params (double-width locals)
//!   doubleAdd    — adds two double params (double-width locals)
//!   returnNull   — returns null (aconst_null + areturn)
//!   intI2l       — widens int to long via i2l
package Jvm.Fuzzer

import Std.Core
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering

func makeVoidNoop(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LReturn)
  val ps: List[JvmType] = newList()
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "voidNoop",
    params = ps,
    ret = JVoid,
    insns = insns,
    maxStack = 0,
    maxLocals = 0
  )
}

func makeConstFortyTwo(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIconst(v = 42))
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "constFortyTwo",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 1,
    maxLocals = 0
  )
}

func makeIntAdd(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIload(slot = 1))
  insns.add(LIadd)
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intAdd",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 2,
    maxLocals = 2
  )
}

func makeIntSub(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIload(slot = 1))
  insns.add(LIsub)
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intSub",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 2,
    maxLocals = 2
  )
}

func makeIntMul(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIload(slot = 1))
  insns.add(LImul)
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intMul",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 2,
    maxLocals = 2
  )
}

func makeIntNeg(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIneg)
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intNeg",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 1,
    maxLocals = 1
  )
}

// max(a, b): if a >= b return a; else return b
func makeIntMax(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIload(slot = 1))
  insns.add(LIfIcmpge(label = "maxThen"))
  insns.add(LIload(slot = 1))
  insns.add(LIreturn)
  insns.add(LLabel(name = "maxThen"))
  insns.add(LIload(slot = 0))
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intMax",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 2,
    maxLocals = 2
  )
}

// abs(a): if a >= 0 return a; else return -a
func makeIntAbs(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIfge(label = "absThen"))
  insns.add(LIload(slot = 0))
  insns.add(LIneg)
  insns.add(LIreturn)
  insns.add(LLabel(name = "absThen"))
  insns.add(LIload(slot = 0))
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intAbs",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 1,
    maxLocals = 1
  )
}

// sum(n): s=0; while n>0 { s+=n; n-=1 }; return s
// params: n at slot 0; local s at slot 1
func makeIntLoop(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = 1))
  insns.add(LLabel(name = "loopHead"))
  insns.add(LIload(slot = 0))
  insns.add(LIfle(label = "loopEnd"))
  insns.add(LIload(slot = 1))
  insns.add(LIload(slot = 0))
  insns.add(LIadd)
  insns.add(LIstore(slot = 1))
  insns.add(LIload(slot = 0))
  insns.add(LIconst(v = 1))
  insns.add(LIsub)
  insns.add(LIstore(slot = 0))
  insns.add(LGoto(label = "loopHead"))
  insns.add(LLabel(name = "loopEnd"))
  insns.add(LIload(slot = 1))
  insns.add(LIreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intLoop",
    params = ps,
    ret = JInt,
    insns = insns,
    maxStack = 2,
    maxLocals = 2
  )
}

func makeLongAdd(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LLload(slot = 0))
  insns.add(LLload(slot = 2))
  insns.add(LLadd)
  insns.add(LLreturn)
  val ps: List[JvmType] = newList()
  ps.add(JLong)
  ps.add(JLong)
  // long occupies 2 slots each: params at 0,1 and 2,3 -> maxLocals=4
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "longAdd",
    params = ps,
    ret = JLong,
    insns = insns,
    maxStack = 4,
    maxLocals = 4
  )
}

func makeDoubleAdd(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LDload(slot = 0))
  insns.add(LDload(slot = 2))
  insns.add(LDadd)
  insns.add(LDreturn)
  val ps: List[JvmType] = newList()
  ps.add(JDouble)
  ps.add(JDouble)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "doubleAdd",
    params = ps,
    ret = JDouble,
    insns = insns,
    maxStack = 4,
    maxLocals = 4
  )
}

func makeReturnNull(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LAconstNull)
  insns.add(LAreturn)
  val ps: List[JvmType] = newList()
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "returnNull",
    params = ps,
    ret = JRef(className = "java/lang/Object"),
    insns = insns,
    maxStack = 1,
    maxLocals = 0
  )
}

func makeIntI2l(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LI2l)
  insns.add(LLreturn)
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "intI2l",
    params = ps,
    ret = JLong,
    insns = insns,
    maxStack = 2,
    maxLocals = 1
  )
}

pub func makeFuzzCorpus(pool: in Pool): List[LFunc] {
  val corpus: List[LFunc] = newList()
  corpus.add(makeVoidNoop())
  corpus.add(makeConstFortyTwo())
  corpus.add(makeIntAdd())
  corpus.add(makeIntSub())
  corpus.add(makeIntMul())
  corpus.add(makeIntNeg())
  corpus.add(makeIntMax())
  corpus.add(makeIntAbs())
  corpus.add(makeIntLoop())
  corpus.add(makeLongAdd())
  corpus.add(makeDoubleAdd())
  corpus.add(makeReturnNull())
  corpus.add(makeIntI2l())
  corpus
}
