//! llvm_ir_self_test.l — self-test for `Lyric.LlvmTypes` + `Lyric.LlvmIr` (N0.2/N0.3).
//!
//! Asserts the `.ll` renderings of the type model, SSA operands, every
//! instruction shape the scalar codegen emits, and a whole minimal module.
//! End-to-end clang acceptance of emitted modules is covered by
//! `llvm_self_test_n1.l` (N1.8); this file is pure string assertions so it
//! runs anywhere.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports the `Lyric.Llvm*` compiler packages):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_ir_self_test.l
@test_module
package Lyric.LlvmIrSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Encoding as Encoding
import Lyric.LlvmTypes
import Lyric.LlvmIr

test "scalar types render" {
  assertEqual(nTypeToIrString(NI32), "i32", "i32")
  assertEqual(nTypeToIrString(NI64), "i64", "i64")
  assertEqual(nTypeToIrString(NI1), "i1", "i1")
  assertEqual(nTypeToIrString(NI8), "i8", "i8")
  assertEqual(nTypeToIrString(NDouble), "double", "double")
  assertEqual(nTypeToIrString(NVoid), "void", "void")
}

test "pointer, struct, array, fn-ptr types render" {
  assertEqual(nTypeToIrString(NPtr(pointee = NI8)), "i8*", "i8*")
  assertEqual(nTypeToIrString(NPtr(pointee = NPtr(pointee = NI8))), "i8**", "i8**")
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NI32)
  assertEqual(nTypeToIrString(NStruct(name = "Lyric.Point", fields = fields)), "%Lyric.Point", "struct ref")
  assertEqual(nTypeToIrString(NArray(elem = NI8, size = 13)), "[13 x i8]", "array")
  val params: List[NType] = newList()
  params.add(NPtr(pointee = NI8))
  params.add(NI32)
  assertEqual(nTypeToIrString(NFnPtr(params = params, ret = NVoid)), "void (i8*, i32)*", "fn ptr")
}

test "operands render" {
  assertEqual(nValueOperandString(NLocal(name = "x")), "%x", "local")
  assertEqual(nValueOperandString(NGlobal(name = "foo")), "@foo", "global")
  assertEqual(nValueOperandString(NLitInt(v = 42i64, ty = NI32)), "42", "int lit")
  assertEqual(nValueOperandString(NLitNull(ty = NPtr(pointee = NI8))), "null", "null")
  assertEqual(nValueToIrString(NLitInt(v = 42i64, ty = NI32)), "i32 42", "typed int lit")
  assertEqual(nValueTypedString(NI32, NLocal(name = "x")), "i32 %x", "typed local")
}

test "float literals render as exact hex bits" {
  // 1.0 = 0x3FF0000000000000; 0.0 = all zeroes; -2.0 = 0xC000000000000000
  assertEqual(nValueOperandString(NLitFloat(v = 1.0)), "0x3FF0000000000000", "1.0")
  assertEqual(nValueOperandString(NLitFloat(v = 0.0)), "0x0000000000000000", "0.0")
  assertEqual(nValueOperandString(NLitFloat(v = -2.0)), "0xC000000000000000", "-2.0")
}

test "identifiers quote only when needed" {
  assertEqual(quoteIrIdent("Hello.main"), "Hello.main", "dotted stays bare")
  assertEqual(quoteIrIdent("x_1$y"), "x_1$y", "bare charset")
  assertEqual(quoteIrIdent("Option[Int]"), "\"Option[Int]\"", "brackets quote")
  assertEqual(quoteIrIdent("9lives"), "\"9lives\"", "leading digit quotes")
}

test "terminators render" {
  assertEqual(emitInsn(NRetVoid), "  ret void", "ret void")
  assertEqual(emitInsn(NRet(ty = NI32, value = NLitInt(v = 0i64, ty = NI32))), "  ret i32 0", "ret i32 0")
  assertEqual(emitInsn(NBr(label = "next")), "  br label %next", "br")
  assertEqual(
    emitInsn(NCondBr(cond = NLocal(name = "c"), thenLabel = "t", elseLabel = "f")),
    "  br i1 %c, label %t, label %f",
    "condbr"
  )
  assertEqual(emitInsn(NUnreachable), "  unreachable", "unreachable")
  val cases: List[NSwitchCase] = newList()
  cases.add(NSwitchCase(matchVal = 0i64, label = "a"))
  cases.add(NSwitchCase(matchVal = 1i64, label = "b"))
  assertEqual(
    emitInsn(NSwitch(ty = NI32, scrutinee = NLocal(name = "d"), defaultLabel = "dflt", cases = cases)),
    "  switch i32 %d, label %dflt [ i32 0, label %a i32 1, label %b ]",
    "switch"
  )
}

test "arithmetic and comparison render" {
  assertEqual(
    emitInsn(NAdd(dest = "r", ty = NI32, a = NLocal(name = "a"), b = NLitInt(v = 1i64, ty = NI32))),
    "  %r = add i32 %a, 1",
    "add"
  )
  assertEqual(
    emitInsn(NICmp(dest = "c", pred = ISlt, ty = NI32, a = NLocal(name = "a"), b = NLocal(name = "b"))),
    "  %c = icmp slt i32 %a, %b",
    "icmp slt"
  )
  assertEqual(
    emitInsn(NFCmp(dest = "c", pred = FOeq, a = NLocal(name = "x"), b = NLocal(name = "y"))),
    "  %c = fcmp oeq double %x, %y",
    "fcmp oeq"
  )
  assertEqual(
    emitInsn(NFAdd(dest = "s", a = NLocal(name = "x"), b = NLocal(name = "y"))),
    "  %s = fadd double %x, %y",
    "fadd"
  )
  assertEqual(
    emitInsn(NXor(dest = "n", ty = NI1, a = NLocal(name = "p"), b = NLitInt(v = 1i64, ty = NI1))),
    "  %n = xor i1 %p, 1",
    "xor (not)"
  )
}

test "memory ops render" {
  assertEqual(emitInsn(NAlloca(dest = "slot", ty = NI32)), "  %slot = alloca i32", "alloca")
  assertEqual(
    emitInsn(NLoad(dest = "v", ty = NI32, ptr = NLocal(name = "slot"))),
    "  %v = load i32, i32* %slot",
    "load"
  )
  assertEqual(
    emitInsn(NStore(ty = NI32, value = NLitInt(v = 7i64, ty = NI32), ptr = NLocal(name = "slot"))),
    "  store i32 7, i32* %slot",
    "store"
  )
  val fields: List[NType] = newList()
  fields.add(NI32)
  val idx: List[NArg] = newList()
  idx.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  idx.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  assertEqual(
    emitInsn(NGEP(dest = "p", ty = NStruct(name = "T", fields = fields), ptr = NLocal(name = "obj"), indices = idx)),
    "  %p = getelementptr inbounds %T, %T* %obj, i32 0, i32 2",
    "gep"
  )
}

test "conversions render" {
  assertEqual(
    emitInsn(NSExt(dest = "l", fromTy = NI32, value = NLocal(name = "i"), toTy = NI64)),
    "  %l = sext i32 %i to i64",
    "sext"
  )
  assertEqual(
    emitInsn(NSIToFP(dest = "f", fromTy = NI32, value = NLocal(name = "i"), toTy = NDouble)),
    "  %f = sitofp i32 %i to double",
    "sitofp"
  )
  assertEqual(
    emitInsn(
      NBitcast(dest = "s", fromTy = NPtr(pointee = NI8), value = NGlobal(name = "g"), toTy = NPtr(pointee = NI32))
    ),
    "  %s = bitcast i8* @g to i32*",
    "bitcast"
  )
}

test "calls and phi render" {
  val args: List[NArg] = newList()
  args.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  args.add(NArg(ty = NI32, value = NLocal(name = "y")))
  assertEqual(
    emitInsn(NCall(dest = "r", retTy = NI32, fn = NGlobal(name = "add2"), args = args)),
    "  %r = call i32 @add2(i32 3, i32 %y)",
    "call"
  )
  val noArgs: List[NArg] = newList()
  assertEqual(emitInsn(NCallVoid(fn = NGlobal(name = "go"), args = noArgs)), "  call void @go()", "call void")
  val inc: List[NPhiIncoming] = newList()
  inc.add(NPhiIncoming(value = NLitInt(v = 1i64, ty = NI32), label = "t"))
  inc.add(NPhiIncoming(value = NLocal(name = "e"), label = "f"))
  assertEqual(emitInsn(NPhi(dest = "m", ty = NI32, incoming = inc)), "  %m = phi i32 [ 1, %t ], [ %e, %f ]", "phi")
  assertEqual(emitInsn(NLabel(name = "entry")), "entry:", "label")
}

test "string bytes escape for c-array constants" {
  assertEqual(escapeIrBytes(Encoding.encodeUtf8("hello")), "hello", "plain ascii")
  assertEqual(escapeIrBytes(Encoding.encodeUtf8("a\"b")), "a\\22b", "quote escapes")
  assertEqual(escapeIrBytes(Encoding.encodeUtf8("a\\b")), "a\\5Cb", "backslash escapes")
  assertEqual(escapeIrBytes(Encoding.encodeUtf8("a\nb")), "a\\0Ab", "newline escapes")
  // U+00E9 is C3 A9 in UTF-8.
  assertEqual(escapeIrBytes(Encoding.encodeUtf8("é")), "\\C3\\A9", "non-ascii escapes bytewise")
}

test "type definitions and globals render" {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NI64)
  fields.add(NI64)
  assertEqual(emitTypeDefn("LyricString", fields), "%LyricString = type { i32, i8*, i64, i64 }", "type defn")
  val g = NGlobalDef(
    linkage = "private unnamed_addr constant",
    name = ".strobj.0",
    tyStr = "{ i32, i8*, i64, i64, [6 x i8] }",
    initStr = "{ i32 2147483647, i8* null, i64 5, i64 6, [6 x i8] c\"hello\\00\" }",
    align = 8
  )
  assertEqual(
    emitGlobal(g),
    "@.strobj.0 = private unnamed_addr constant { i32, i8*, i64, i64, [6 x i8] } " +
      "{ i32 2147483647, i8* null, i64 5, i64 6, [6 x i8] c\"hello\\00\" }, align 8",
    "global"
  )
}

test "a minimal module renders whole" {
  val noParams: List[NParam] = newList()
  val noAttrs: List[String] = newList()
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  body.add(NRet(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  val mainFn = NFunc(
    name = "main",
    params = noParams,
    retTy = NI32,
    isPublic = true,
    isExtern = false,
    body = body,
    attributes = noAttrs
  )
  val fns: List[NFunc] = newList()
  fns.add(mainFn)
  val noTypes: List[NTypeDefn] = newList()
  val noGlobals: List[NGlobalDef] = newList()
  val noExterns: List[NFunc] = newList()
  val noLibs: List[String] = newList()
  val pkg = NPackage(
    name = "Mini",
    triple = "x86_64-unknown-linux-gnu",
    types = noTypes,
    globals = noGlobals,
    functions = fns,
    externDecls = noExterns,
    nativeLibs = noLibs
  )
  val ll = emitModule(pkg)
  assertEqual(
    ll,
    "; ModuleID = 'Mini'\n" +
      "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n" +
      "target triple = \"x86_64-unknown-linux-gnu\"\n" +
      "\n" +
      "define i32 @main() {\n" +
      "entry:\n" +
      "  ret i32 0\n" +
      "}\n",
    "whole module"
  )
}

test "extern declarations render" {
  val params: List[NParam] = newList()
  params.add(NParam(name = "fd", ty = NI32))
  params.add(NParam(name = "buf", ty = NPtr(pointee = NI8)))
  params.add(NParam(name = "n", ty = NI64))
  val noAttrs: List[String] = newList()
  val noBody: List[NInsn] = newList()
  val decl = NFunc(
    name = "write",
    params = params,
    retTy = NI64,
    isPublic = true,
    isExtern = true,
    body = noBody,
    attributes = noAttrs
  )
  assertEqual(emitFuncDecl(decl), "declare i64 @write(i32, i8*, i64)", "declare")
}
