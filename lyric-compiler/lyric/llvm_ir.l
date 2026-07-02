//! llvm/ir.l — LLVM `.ll` textual IR data model and serialiser (N0.3).
//!
//! Defines the instruction set (`NInsn`), function/global/package shapes,
//! and renders them as clang-acceptable textual IR.  The shapes follow
//! native/plan/02-architecture.md with these corrections, applied because
//! the plan's sketches would render invalid IR:
//!
//!   * Binary-op operands render the type once (`add i32 %a, 1`), not
//!     per-operand as the plan's N0.3 acceptance line sketched
//!     (`add i32 %a, i32 1` is not valid LLVM syntax).
//!   * `NStore`, `NSwitch`, and value-returning `NRet` carry the operand
//!     type explicitly — locals have no intrinsic type, so the sketch
//!     shapes could not be rendered for non-literal operands.
//!   * Call arguments / GEP indices / phi incoming edges are small
//!     records (`NArg`, `NSwitchCase`, `NPhiIncoming`) rather than raw
//!     tuples, keeping match sites self-describing.
//!
//! Formatting: instructions indent two spaces, labels sit at column 0,
//! one blank line between function definitions, `target datalayout` /
//! `target triple` at the top.
package Lyric.LlvmIr

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch
import Lyric.LlvmTypes

// ── Instruction operand shapes ───────────────────────────────────────────────
pub record NArg {
  ty: NType
  value: NValue
}

pub record NSwitchCase {
  matchVal: Long
  label: String
}

pub record NPhiIncoming {
  value: NValue
  label: String
}

// ── Instructions ─────────────────────────────────────────────────────────────
pub union NInsn {
  // Terminators
  case NRetVoid
  case NRet(ty: NType, value: NValue)
  case NBr(label: String)
  case NCondBr(cond: NValue, thenLabel: String, elseLabel: String)
  case NSwitch(ty: NType, scrutinee: NValue, defaultLabel: String, cases: List[NSwitchCase])
  case NUnreachable

  // Memory
  case NAlloca(dest: String, ty: NType)
  case NLoad(dest: String, ty: NType, ptr: NValue)
  case NStore(ty: NType, value: NValue, ptr: NValue)
  case NGEP(dest: String, ty: NType, ptr: NValue, indices: List[NArg])

  // Integer arithmetic
  case NAdd(dest: String, ty: NType, a: NValue, b: NValue)
  case NSub(dest: String, ty: NType, a: NValue, b: NValue)
  case NMul(dest: String, ty: NType, a: NValue, b: NValue)
  case NSDiv(dest: String, ty: NType, a: NValue, b: NValue)
  case NSRem(dest: String, ty: NType, a: NValue, b: NValue)

  // Float arithmetic
  case NFAdd(dest: String, a: NValue, b: NValue)
  case NFSub(dest: String, a: NValue, b: NValue)
  case NFMul(dest: String, a: NValue, b: NValue)
  case NFDiv(dest: String, a: NValue, b: NValue)
  case NFRem(dest: String, a: NValue, b: NValue)
  case NFNeg(dest: String, a: NValue)

  // Bitwise
  case NShl(dest: String, ty: NType, a: NValue, b: NValue)
  case NAShr(dest: String, ty: NType, a: NValue, b: NValue)
  case NAnd(dest: String, ty: NType, a: NValue, b: NValue)
  case NOr(dest: String, ty: NType, a: NValue, b: NValue)
  case NXor(dest: String, ty: NType, a: NValue, b: NValue)

  // Comparison
  case NICmp(dest: String, pred: ICmpPred, ty: NType, a: NValue, b: NValue)
  case NFCmp(dest: String, pred: FCmpPred, a: NValue, b: NValue)

  // Conversion
  case NSExt(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NZExt(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NTrunc(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NBitcast(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NSIToFP(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NFPToSI(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NPtrToInt(dest: String, fromTy: NType, value: NValue, toTy: NType)
  case NIntToPtr(dest: String, fromTy: NType, value: NValue, toTy: NType)

  // Calls.  `fn` is usually NGlobal for direct calls, NLocal for
  // indirect calls through a loaded function pointer.
  case NCall(dest: String, retTy: NType, fn: NValue, args: List[NArg])
  case NCallVoid(fn: NValue, args: List[NArg])

  // SSA merge
  case NPhi(dest: String, ty: NType, incoming: List[NPhiIncoming])

  // Basic-block marker (renders as `name:` at column 0)
  case NLabel(name: String)

  // `; text` — debugging aid; carries no semantics.
  case NComment(text: String)
}

// ── Functions / globals / package ────────────────────────────────────────────
pub record NParam {
  name: String
  ty: NType
}

pub record NFunc {
  name: String
  params: List[NParam]
  retTy: NType
  isPublic: Bool
  /// true = `declare` only (extern func / runtime intrinsics)
  isExtern: Bool
  body: List[NInsn]
  /// e.g. "nounwind"; rendered after the parameter list
  attributes: List[String]
}

/// A global constant.  The initializer (and its type, which for string
/// literals includes the inline `[N x i8]` data array) is pre-rendered
/// by the codegen's typed helpers; `emitGlobal` only assembles the line.
pub record NGlobalDef {
  name: String
  /// e.g. "private unnamed_addr constant"
  linkage: String
  tyStr: String
  initStr: String
  align: Int
}

pub record NTypeDefn {
  name: String
  fields: List[NType]
}

pub record NPackage {
  name: String
  triple: String
  types: List[NTypeDefn]
  globals: List[NGlobalDef]
  functions: List[NFunc]
  externDecls: List[NFunc]
  /// Library names from `@nativeLib` annotations, threaded to the
  /// linker invocation (N4.3 / N6.1).
  nativeLibs: List[String]
}

// ── Datalayout selection ─────────────────────────────────────────────────────
/// The `target datalayout` string for a Phase 1 triple (D-N-008).
/// macOS layouts use Mach-O mangling (`m:o`) — including x86-64, where
/// the plan's "same as Linux" note would mis-mangle symbols.
pub func datalayoutForTriple(triple: in String): String {
  val isApple = Str.contains(triple, "apple")
  if Str.startsWith(triple, "x86_64") {
    if isApple {
      "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
    } else {
      "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
    }
  } else if Str.startsWith(triple, "aarch64") or Str.startsWith(triple, "arm64") {
    if isApple {
      "e-m:o-i64:64-i128:128-n32:64-S128"
    } else {
      "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128"
    }
  } else {
    // Unknown triple: emit no datalayout line and let clang derive it
    // from the triple.  Signalled by the empty string.
    ""
  }
}

// ── Escaping ─────────────────────────────────────────────────────────────────
func byteToHex2(b: in Int): String {
  val digits = "0123456789ABCDEF"
  Str.substring(digits, b / 16, 1) + Str.substring(digits, b % 16, 1)
}

/// Render raw bytes as the body of a `c"..."` array constant.  Printable
/// ASCII (except `"` and `\`) passes through; everything else escapes as
/// `\XX` uppercase hex, which is the only escape form `.ll` accepts.
pub func escapeIrBytes(bytes: in slice[Byte]): String {
  var acc = ""
  var i = 0
  while i < bytes.length {
    val b = bytes[i].toInt()
    if b >= 32 and b <= 126 and b != 34 and b != 92 {
      acc = acc + ("" + Ch.fromInt(b))
    } else {
      acc = acc + "\\" + byteToHex2(b)
    }
    i = i + 1
  }
  acc
}

// ── Rendering ────────────────────────────────────────────────────────────────
func icmpPredString(p: in ICmpPred): String {
  match p {
    case IEq -> "eq"
    case INe -> "ne"
    case ISlt -> "slt"
    case ISle -> "sle"
    case ISgt -> "sgt"
    case ISge -> "sge"
    case IUlt -> "ult"
    case IUle -> "ule"
    case IUgt -> "ugt"
    case IUge -> "uge"
  }
}

func fcmpPredString(p: in FCmpPred): String {
  match p {
    case FOeq -> "oeq"
    case FOne -> "one"
    case FOlt -> "olt"
    case FOle -> "ole"
    case FOgt -> "ogt"
    case FOge -> "oge"
    case FUne -> "une"
  }
}

func renderArgs(args: in List[NArg]): String {
  var acc = ""
  var i = 0
  while i < args.count {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + nValueTypedString(args[i].ty, args[i].value)
    i = i + 1
  }
  acc
}

func renderBin(op: in String, dest: in String, ty: in NType, a: in NValue, b: in NValue): String {
  "  %" + quoteIrIdent(dest) + " = " + op + " " + nTypeToIrString(ty) + " " + nValueOperandString(a) + ", " +
    nValueOperandString(b)
}

func renderFBin(op: in String, dest: in String, a: in NValue, b: in NValue): String {
  "  %" + quoteIrIdent(dest) + " = " + op + " double " + nValueOperandString(a) + ", " + nValueOperandString(b)
}

func renderConv(op: in String, dest: in String, fromTy: in NType, value: in NValue, toTy: in NType): String {
  "  %" + quoteIrIdent(dest) + " = " + op + " " + nTypeToIrString(fromTy) + " " + nValueOperandString(value) + " to " +
    nTypeToIrString(toTy)
}

/// Render one instruction (or label / comment) as its `.ll` line.
pub func emitInsn(i: in NInsn): String {
  match i {
    case NRetVoid -> "  ret void"
    case NRet(ty, value) -> "  ret " + nValueTypedString(ty, value)
    case NBr(label) -> "  br label %" + quoteIrIdent(label)
    case NCondBr(cond, thenLabel, elseLabel) -> {
      "  br i1 " + nValueOperandString(cond) + ", label %" + quoteIrIdent(thenLabel) + ", label %" + quoteIrIdent(elseLabel)
    }
    case NSwitch(ty, scrutinee, defaultLabel, cases) -> {
      var acc = "  switch " + nTypeToIrString(ty) + " " + nValueOperandString(scrutinee) + ", label %" +
        quoteIrIdent(defaultLabel) +
        " ["
      var ci = 0
      while ci < cases.count {
        acc = acc + " " + nTypeToIrString(ty) + " " + cases[ci].matchVal.toString() + ", label %" +
          quoteIrIdent(cases[ci].label)
        ci = ci + 1
      }
      acc + " ]"
    }
    case NUnreachable -> "  unreachable"
    case NAlloca(dest, ty) -> "  %" + quoteIrIdent(dest) + " = alloca " + nTypeToIrString(ty)
    case NLoad(dest, ty, ptr) -> {
      "  %" + quoteIrIdent(dest) + " = load " + nTypeToIrString(ty) + ", " + nTypeToIrString(ty) + "* " +
        nValueOperandString(ptr)
    }
    case NStore(ty, value, ptr) -> {
      "  store " + nValueTypedString(ty, value) + ", " + nTypeToIrString(ty) + "* " + nValueOperandString(ptr)
    }
    case NGEP(dest, ty, ptr, indices) -> {
      "  %" + quoteIrIdent(dest) + " = getelementptr inbounds " + nTypeToIrString(ty) + ", " + nTypeToIrString(ty) + "* " +
        nValueOperandString(ptr) +
        ", " +
        renderArgs(indices)
    }
    case NAdd(dest, ty, a, b) -> renderBin("add", dest, ty, a, b)
    case NSub(dest, ty, a, b) -> renderBin("sub", dest, ty, a, b)
    case NMul(dest, ty, a, b) -> renderBin("mul", dest, ty, a, b)
    case NSDiv(dest, ty, a, b) -> renderBin("sdiv", dest, ty, a, b)
    case NSRem(dest, ty, a, b) -> renderBin("srem", dest, ty, a, b)
    case NFAdd(dest, a, b) -> renderFBin("fadd", dest, a, b)
    case NFSub(dest, a, b) -> renderFBin("fsub", dest, a, b)
    case NFMul(dest, a, b) -> renderFBin("fmul", dest, a, b)
    case NFDiv(dest, a, b) -> renderFBin("fdiv", dest, a, b)
    case NFRem(dest, a, b) -> renderFBin("frem", dest, a, b)
    case NFNeg(dest, a) -> "  %" + quoteIrIdent(dest) + " = fneg double " + nValueOperandString(a)
    case NShl(dest, ty, a, b) -> renderBin("shl", dest, ty, a, b)
    case NAShr(dest, ty, a, b) -> renderBin("ashr", dest, ty, a, b)
    case NAnd(dest, ty, a, b) -> renderBin("and", dest, ty, a, b)
    case NOr(dest, ty, a, b) -> renderBin("or", dest, ty, a, b)
    case NXor(dest, ty, a, b) -> renderBin("xor", dest, ty, a, b)
    case NICmp(dest, pred, ty, a, b) -> renderBin("icmp " + icmpPredString(pred), dest, ty, a, b)
    case NFCmp(dest, pred, a, b) -> renderFBin("fcmp " + fcmpPredString(pred), dest, a, b)
    case NSExt(dest, fromTy, value, toTy) -> renderConv("sext", dest, fromTy, value, toTy)
    case NZExt(dest, fromTy, value, toTy) -> renderConv("zext", dest, fromTy, value, toTy)
    case NTrunc(dest, fromTy, value, toTy) -> renderConv("trunc", dest, fromTy, value, toTy)
    case NBitcast(dest, fromTy, value, toTy) -> renderConv("bitcast", dest, fromTy, value, toTy)
    case NSIToFP(dest, fromTy, value, toTy) -> renderConv("sitofp", dest, fromTy, value, toTy)
    case NFPToSI(dest, fromTy, value, toTy) -> renderConv("fptosi", dest, fromTy, value, toTy)
    case NPtrToInt(dest, fromTy, value, toTy) -> renderConv("ptrtoint", dest, fromTy, value, toTy)
    case NIntToPtr(dest, fromTy, value, toTy) -> renderConv("inttoptr", dest, fromTy, value, toTy)
    case NCall(dest, retTy, fn, args) -> {
      "  %" + quoteIrIdent(dest) + " = call " + nTypeToIrString(retTy) + " " + nValueOperandString(fn) + "(" +
        renderArgs(args) +
        ")"
    }
    case NCallVoid(fn, args) -> "  call void " + nValueOperandString(fn) + "(" + renderArgs(args) + ")"
    case NPhi(dest, ty, incoming) -> {
      var acc = "  %" + quoteIrIdent(dest) + " = phi " + nTypeToIrString(ty) + " "
      var pi = 0
      while pi < incoming.count {
        if pi > 0 {
          acc = acc + ", "
        }
        acc = acc + "[ " + nValueOperandString(incoming[pi].value) + ", %" + quoteIrIdent(incoming[pi].label) + " ]"
        pi = pi + 1
      }
      acc
    }
    case NLabel(name) -> quoteIrIdent(name) + ":"
    case NComment(text) -> "  ; " + text
  }
}

/// Emit a named struct type definition: `%Name = type { i32, i8* }`.
/// A field-less definition renders as an opaque type (`type {}`).
pub func emitTypeDefn(name: in String, fields: in List[NType]): String {
  if fields.count == 0 {
    "%" + quoteIrIdent(name) + " = type {}"
  } else {
    "%" + quoteIrIdent(name) + " = type " + nStructBodyString(fields)
  }
}

/// Emit a global constant line.
pub func emitGlobal(g: in NGlobalDef): String {
  var line = "@" + quoteIrIdent(g.name) + " = " + g.linkage + " " + g.tyStr + " " + g.initStr
  if g.align > 0 {
    line = line + ", align " + g.align.toString()
  }
  line
}

func renderParams(params: in List[NParam], withNames: in Bool): String {
  var acc = ""
  var i = 0
  while i < params.count {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + nTypeToIrString(params[i].ty)
    if withNames {
      acc = acc + " %" + quoteIrIdent(params[i].name)
    }
    i = i + 1
  }
  acc
}

/// Emit a `declare` line for an extern function.
pub func emitFuncDecl(f: in NFunc): String {
  var line = "declare " + nTypeToIrString(f.retTy) + " @" + quoteIrIdent(f.name) + "(" + renderParams(f.params, false) +
    ")"
  var ai = 0
  while ai < f.attributes.count {
    line = line + " " + f.attributes[ai]
    ai = ai + 1
  }
  line
}

/// Emit a full `define ... { ... }` block.
pub func emitFuncDefn(f: in NFunc): String {
  val linkage = if f.isPublic { "" } else { "internal " }
  var head = "define " + linkage + nTypeToIrString(f.retTy) + " @" + quoteIrIdent(f.name) + "(" +
    renderParams(f.params, true) +
    ")"
  var ai = 0
  while ai < f.attributes.count {
    head = head + " " + f.attributes[ai]
    ai = ai + 1
  }
  val lines: List[String] = newList()
  lines.add(head + " {")
  var i = 0
  while i < f.body.count {
    lines.add(emitInsn(f.body[i]))
    i = i + 1
  }
  lines.add("}")
  Str.joinList("\n", lines)
}

/// Emit the whole module: header, type definitions, globals, extern
/// declarations, then function definitions separated by blank lines.
pub func emitModule(pkg: in NPackage): String {
  val lines: List[String] = newList()
  lines.add("; ModuleID = '" + pkg.name + "'")
  val layout = datalayoutForTriple(pkg.triple)
  if layout.length > 0 {
    lines.add("target datalayout = \"" + layout + "\"")
  }
  if pkg.triple.length > 0 {
    lines.add("target triple = \"" + pkg.triple + "\"")
  }
  lines.add("")
  var ti = 0
  while ti < pkg.types.count {
    lines.add(emitTypeDefn(pkg.types[ti].name, pkg.types[ti].fields))
    ti = ti + 1
  }
  if pkg.types.count > 0 {
    lines.add("")
  }
  var gi = 0
  while gi < pkg.globals.count {
    lines.add(emitGlobal(pkg.globals[gi]))
    gi = gi + 1
  }
  if pkg.globals.count > 0 {
    lines.add("")
  }
  var ei = 0
  while ei < pkg.externDecls.count {
    lines.add(emitFuncDecl(pkg.externDecls[ei]))
    ei = ei + 1
  }
  if pkg.externDecls.count > 0 {
    lines.add("")
  }
  var fi = 0
  while fi < pkg.functions.count {
    lines.add(emitFuncDefn(pkg.functions[fi]))
    lines.add("")
    fi = fi + 1
  }
  Str.joinList("\n", lines)
}
