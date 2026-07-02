//! llvm/types.l — LLVM IR type and SSA-value model for the native backend
//! (work item N0.2, native/plan/02-architecture.md).
//!
//! `NType` mirrors the LLVM first-class type grammar the backend needs;
//! `NValue` is an SSA operand.  `nTypeToIrString` / `nValueToIrString`
//! render them in `.ll` textual syntax.
//!
//! Naming note: the plan sketches the function-pointer case as `NFunc`,
//! but that name is taken by the function-definition record in
//! `Lyric.LlvmLowering` (also from the plan); the case is `NFnPtr` here so the
//! two can coexist in one importing scope.
package Lyric.LlvmTypes

import Std.Core
import Std.Collections
import Std.String as Str

pub union NType {
  case NVoid
  case NI1
  case NI8
  case NI32
  case NI64
  case NDouble
  case NPtr(pointee: NType)
  case NStruct(name: String, fields: List[NType])
  /// Anonymous (literal) struct type — renders as `{ i32, i8* }` inline.
  /// Used where a value's type is a one-off shape (e.g. a string-literal
  /// global whose tail is the inline `[N x i8]` data array).
  case NLitStruct(fields: List[NType])
  case NFnPtr(params: List[NType], ret: NType)
  case NArray(elem: NType, size: Int)
}

pub union NValue {
  case NLocal(name: String)
  case NGlobal(name: String)
  case NLitInt(v: Long, ty: NType)
  case NLitFloat(v: Double)
  case NLitNull(ty: NType)
  case NUndef(ty: NType)
}

/// Signed/unsigned integer comparison predicates (`icmp <pred>`).
pub union ICmpPred {
  case IEq
  case INe
  case ISlt
  case ISle
  case ISgt
  case ISge
  case IUlt
  case IUle
  case IUgt
  case IUge
}

/// Ordered float comparison predicates (`fcmp <pred>`).  Only the
/// ordered forms are used: Lyric float comparisons are false on NaN
/// operands except `!=`, which lowers through `une`.
pub union FCmpPred {
  case FOeq
  case FOne
  case FOlt
  case FOle
  case FOgt
  case FOge
  case FUne
}

/// Render an `NType` as its `.ll` spelling.  Struct types render as the
/// `%Name` reference; the definition line is emitted separately by
/// `Lyric.LlvmIr.emitTypeDefn`.
pub func nTypeToIrString(t: in NType): String {
  match t {
    case NVoid -> "void"
    case NI1 -> "i1"
    case NI8 -> "i8"
    case NI32 -> "i32"
    case NI64 -> "i64"
    case NDouble -> "double"
    case NPtr(pointee) -> nTypeToIrString(pointee) + "*"
    case NStruct(name, _) -> "%" + quoteIrIdent(name)
    case NLitStruct(fields) -> nStructBodyString(fields)
    case NFnPtr(params, ret) -> {
      var acc = nTypeToIrString(ret) + " ("
      var i = 0
      while i < params.count {
        if i > 0 {
          acc = acc + ", "
        }
        acc = acc + nTypeToIrString(params[i])
        i = i + 1
      }
      acc + ")*"
    }
    case NArray(elem, size) -> "[" + size.toString() + " x " + nTypeToIrString(elem) + "]"
  }
}

/// Render an anonymous (literal) struct type body: `{ i32, i8* }`.
/// Used for payload casts in union lowering and for static string
/// globals whose initializer type carries the inline data array.
pub func nStructBodyString(fields: in List[NType]): String {
  var acc = "{ "
  var i = 0
  while i < fields.count {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + nTypeToIrString(fields[i])
    i = i + 1
  }
  acc + " }"
}

/// True when the character is valid in a bare LLVM identifier
/// ([a-zA-Z$._][a-zA-Z$._0-9]*).
func isBareIrIdentChar(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '$' or c == '.' or c == '_'
}

/// Quote an identifier for use after `%` / `@` when it contains
/// characters outside the bare LLVM identifier set.  Lyric package
/// qualifiers use dots (valid bare); mangled generic names can carry
/// other characters, which need the quoted `"..."` form.
pub func quoteIrIdent(name: in String): String {
  var needsQuote = name.length == 0
  var i = 0
  while i < name.length {
    match Str.charAt(name, i) {
      case Some(c) -> {
        if not isBareIrIdentChar(c) {
          needsQuote = true
        }
        // A leading digit forces quoting: bare identifiers must not
        // start with [0-9] (those are unnamed temporaries).
        if i == 0 and c >= '0' and c <= '9' {
          needsQuote = true
        }
      }
      case None -> ()
    }
    i = i + 1
  }
  if needsQuote {
    "\"" + name + "\""
  } else {
    name
  }
}

// IEEE-754 bit extraction for exact float-constant rendering.  LLVM
// textual IR requires float constants to be bit-exact; the only
// always-exact spelling is the 0x-prefixed 16-hex-digit form of the
// raw double bits.
@externTarget("System.BitConverter.DoubleToInt64Bits")
func doubleToInt64Bits(v: in Double): Long = ()

// Two's-complement hex of a signed 64-bit value (lowercase, unpadded).
// A BCL boundary rather than `.shr`/`.and` bit-fiddling: the bitwise
// integer methods are self-hosted-only surface (#1610) that the frozen
// F# mint seed cannot compile, and this package must stay
// seed-compilable for the bootstrap.
@externTarget("System.Convert.ToString")
func longToHexRaw(v: in Long, toBase: in Int): String = ()

/// The 16-hex-digit spelling of a Long's raw bits (no 0x prefix).
pub func longToHex16(bits: in Long): String {
  var acc = Str.toUpper(longToHexRaw(bits, 16))
  while acc.length < 16 {
    acc = "0" + acc
  }
  acc
}

/// Render a Double as LLVM's always-exact hexadecimal float constant
/// (`0x` + the 16 hex digits of the IEEE-754 bits).  Decimal spellings
/// are only legal in `.ll` when they round-trip exactly; the hex form
/// removes that hazard for every value including NaN and infinities.
pub func floatToIrString(v: in Double): String {
  "0x" + longToHex16(doubleToInt64Bits(v))
}

/// Render an operand WITHOUT its type prefix (the form used where the
/// instruction spells the type once, e.g. `add i32 %a, 1`).
pub func nValueOperandString(v: in NValue): String {
  match v {
    case NLocal(name) -> "%" + quoteIrIdent(name)
    case NGlobal(name) -> "@" + quoteIrIdent(name)
    case NLitInt(value, _) -> value.toString()
    case NLitFloat(value) -> floatToIrString(value)
    case NLitNull(_) -> "null"
    case NUndef(_) -> "undef"
  }
}

/// The static type carried by a literal operand; None for locals and
/// globals (whose types the instruction context supplies).
pub func nValueType(v: in NValue): Option[NType] {
  match v {
    case NLocal(_) -> None
    case NGlobal(_) -> None
    case NLitInt(_, ty) -> Some(value = ty)
    case NLitFloat(_) -> Some(value = NDouble)
    case NLitNull(ty) -> Some(value = ty)
    case NUndef(ty) -> Some(value = ty)
  }
}

/// Render an operand WITH a type prefix, for positions that require the
/// `<ty> <val>` pair (call arguments, ret, phi incoming, globals).
/// Locals/globals carry no intrinsic type, so the caller supplies one.
pub func nValueTypedString(ty: in NType, v: in NValue): String {
  nTypeToIrString(ty) + " " + nValueOperandString(v)
}

/// Render a literal operand with its own carried type (`i32 42`).
/// Panics for locals/globals — use `nValueTypedString` there.
pub func nValueToIrString(v: in NValue): String {
  match nValueType(v) {
    case Some(ty) -> nValueTypedString(ty, v)
    case None -> panic("nValueToIrString: operand carries no type; use nValueTypedString: " + nValueOperandString(v))
  }
}
