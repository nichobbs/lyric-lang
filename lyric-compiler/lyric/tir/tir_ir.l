//! tir_ir.l - Lyric.Tir: the typed IR (docs/70 §6.2, D319).
//!
//! `TExpr` is a separate set of types, not an annotated AST: a TIR value
//! cannot exist without its types.  Every implicit operation is a node
//! (`XConvert`), every call has a resolved `Callee` and its arguments in
//! parameter order with defaults filled in, and a name is a `SymbolId` or a
//! `LocalId`, never a string to look up.  `Lyric.Tir.Verify` checks the
//! invariants this model cannot state by construction.
package Lyric.Tir

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols

/// A field of a record, an exposed record or a union case: the declaring
/// symbol, the field's name, and its position among the declaration's fields.
pub record FieldRef {
  owner: SymbolId
  name: String
  index: Int
}

/// What a host member is.
pub union HostMemberKind {
  case HMMethod
  case HMConstructor
  case HMPropertyGet
  case HMPropertySet
  case HMFieldGet
  case HMFieldSet
  case HMIndexerGet
  case HMIndexerSet
}

/// A member of a host type, resolved from the host's metadata at check time
/// (docs/70 §5.3).  `params` and `ret` are the member's signature as Lyric
/// types, with the owner's type arguments substituted.
pub record HostMemberRef {
  owner: HostTypeRef
  name: String
  kind: HostMemberKind
  isStatic: Bool
  params: List[TParamTy]
  ret: Ty
}

/// The operations the compiler implements itself on built-in types: the
/// arithmetic, comparison and logic of scalars, and the named built-ins.
/// Operators on declared types are calls to their `Direct` method instead.
pub union IntrinsicOp {
  case IoAdd
  case IoSub
  case IoMul
  case IoDiv
  case IoMod
  case IoNeg
  case IoNot
  case IoBitAnd
  case IoBitOr
  case IoBitXor
  case IoEq
  case IoNeq
  case IoLt
  case IoLte
  case IoGt
  case IoGte
  /// A built-in function by its name in the built-in table (`println`,
  /// `toString`, ...), whose signature is declared there.
  case IoBuiltin(name: String)
  /// `T.tryFrom(x)` on a distinct or range type `T`: the argument (the
  /// underlying type) checked into `T`, as `Result[T, String]`; `T` is the first
  /// type argument of the node's type.
  case IoTryFrom
}

pub union Callee {
  /// A declared function or method, instantiated at `typeArgs`.
  case Direct(sym: SymbolId, typeArgs: List[Ty])
  /// A method of an interface, dispatched on the receiver; `ifaceArgs` are the
  /// interface's own type arguments.
  case Interface(iface: SymbolId, ifaceArgs: List[Ty], method: SymbolId, typeArgs: List[Ty])
  /// A call through a function value.
  case Indirect(fnValue: TExpr)
  case Extern(member: HostMemberRef)
  case Intrinsic(op: IntrinsicOp)
}

/// An argument, with its mode.  `out` and `inout` arguments are places.
pub union TArg {
  case TArgIn(value: TExpr)
  case TArgOut(place: TPlace)
  case TArgInout(place: TPlace)
}

/// How an index expression is performed.
pub union IndexKind {
  case IkArray
  case IkSlice
  case IkString
  case IkList
  case IkMap
  /// The built-in `buffer[T]`: an element read or write, bounds-checked.
  case IkBuffer
  /// A record's `index` method.
  case IkMethod(sym: SymbolId)
  case IkHost(member: HostMemberRef)
}

/// The conversions the checker accepts implicitly, made explicit.  The source
/// type is `inner.ty`; the result type is the node's `ty`.
pub union ConvKind {
  /// Numeric widening to `to`.
  case CvWiden(to: TPrimKind)
  /// A value of the underlying type becomes the distinct type `sym`.
  case CvWrapDistinct(sym: SymbolId)
  case CvUnwrapDistinct(sym: SymbolId)
  /// A check that the value lies in the node type's range; panics otherwise.
  case CvRangeCheck
  /// A refined value used as its underlying type.
  case CvUnrefine
  /// A value used as an interface it implements.
  case CvUpcast(iface: SymbolId)
  /// A Lyric value passed as a host type.
  case CvBoxToHost(host: HostTypeRef)
  case CvToSlice
  case CvToList
  /// `T` used as `T?`.
  case CvLiftNullable
  /// An expression of type `Never` used where a value is expected.
  case CvFromNever
}

pub union ShortOp {
  case ShAnd
  case ShOr
  case ShImplies
  case ShCoalesce
}

pub union AssignKind {
  case AkSet
  case AkAdd
  case AkSub
  case AkMul
  case AkDiv
  case AkMod
}

pub union CaptureMode {
  case CmByValue
  case CmByRef
}

pub record Capture {
  local: LocalId
  mode: CaptureMode
}

/// A local variable, parameter or pattern binding.
pub record LocalDecl {
  id: LocalId
  name: String
  ty: Ty
  mutable: Bool
}

pub union TLit {
  case TLInt(value: Long)
  case TLFloat(value: Double)
  case TLChar(codepoint: Int)
  case TLString(text: String)
  case TLBool(value: Bool)
  case TLUnit
}

pub record TPlace {
  ty: Ty
  kind: TPlaceKind
}

pub union TPlaceKind {
  case PlLocal(local: LocalId)
  case PlGlobal(sym: SymbolId)
  case PlField(recv: TExpr, field: FieldRef)
  case PlIndex(recv: TExpr, idx: TExpr, how: IndexKind)
}

pub record TPat {
  id: NodeId
  ty: Ty
  span: Span
  kind: TPatKind
}

pub record TFieldPat {
  field: FieldRef
  pat: TPat
}

pub union TPatKind {
  case TpWild
  /// Binds the matched value; `inner` further restricts it (`x @ pat`).
  case TpBind(decl: LocalDecl, inner: Option[TPat])
  case TpLit(lit: TLit)
  case TpRange(lo: TLit, hi: TLit, inclusive: Bool)
  /// A union or enum case, with one pattern per payload field.
  case TpCtor(sym: SymbolId, args: List[TPat])
  case TpRecord(sym: SymbolId, fields: List[TFieldPat])
  case TpTuple(elems: List[TPat])
  case TpTypeTest(inner: TPat, ty: Ty)
  /// Every alternative binds the same locals.
  case TpOr(alts: List[TPat])
  /// A reference to a compile-time constant (`@NAME`).
  case TpConst(sym: SymbolId)
}

pub record TArm {
  pat: TPat
  guard: Option[TExpr]
  body: TExpr
}

pub record TCatch {
  binding: Option[LocalDecl]
  exceptionType: String
  body: TExpr
}

/// A field a record copy replaces, with its new value.
pub record TFieldUpdate {
  field: FieldRef
  value: TExpr
}

pub record TExpr {
  id: NodeId
  ty: Ty
  span: Span
  kind: TExprKind
}

pub union TExprKind {
  case XLit(lit: TLit)
  case XLocal(local: LocalId)
  case XGlobal(sym: SymbolId, typeArgs: List[Ty])
  case XCall(callee: Callee, args: List[TArg])
  /// A record or union case value; `fields` are in declaration order with
  /// defaults filled in.
  case XConstruct(sym: SymbolId, fields: List[TExpr])
  case XField(recv: TExpr, field: FieldRef)
  /// A record `.copy(...)`: the value of `base` with the listed fields replaced, of the
  /// same type.  `base` is evaluated once, before the updates, which run in source order.
  case XCopy(base: TExpr, updates: List[TFieldUpdate])
  case XIndex(recv: TExpr, idx: TExpr, how: IndexKind)
  case XConvert(kind: ConvKind, inner: TExpr)
  case XTuple(elems: List[TExpr])
  case XListLit(elems: List[TExpr])
  /// Every part is a `String`: literal text is an `XLit`.
  case XInterp(parts: List[TExpr])
  case XRange(lo: TExpr, hi: TExpr, inclusive: Bool)
  case XShort(op: ShortOp, lhs: TExpr, rhs: TExpr)
  case XIf(cond: TExpr, thenBranch: TExpr, elseBranch: Option[TExpr])
  case XMatch(scrutinee: TExpr, arms: List[TArm], exhaustive: Bool)
  case XBlock(stmts: List[TStmt], tail: Option[TExpr])
  case XUnsafe(body: TExpr)
  case XLambda(params: List[LocalDecl], captures: List[Capture], body: TExpr)
  case XAwait(inner: TExpr)
  case XSpawn(inner: TExpr)
  case XYield(inner: TExpr)
  /// The `?` operator on a `Result` or `Option` operand.
  case XPropagate(inner: TExpr)
  case XOld(inner: TExpr)
  case XResult
  case XForall(binders: List[LocalDecl], whereExpr: Option[TExpr], body: TExpr)
  case XExists(binders: List[LocalDecl], whereExpr: Option[TExpr], body: TExpr)
  case XAssign(place: TPlace, op: AssignKind, value: TExpr)
}

pub record TStmt {
  id: NodeId
  span: Span
  kind: TStmtKind
}

pub union TStmtKind {
  case TsLet(pat: TPat, init: TExpr)
  case TsVar(decl: LocalDecl, init: Option[TExpr])
  case TsExpr(expr: TExpr)
  case TsReturn(value: Option[TExpr])
  case TsBreak(label: Option[String])
  case TsContinue(label: Option[String])
  case TsThrow(expr: TExpr)
  case TsTry(body: TExpr, catches: List[TCatch], finallyBody: Option[TExpr])
  case TsDefer(body: TExpr)
  case TsScope(binding: Option[LocalDecl], body: TExpr)
  case TsFor(label: Option[String], pat: TPat, iter: TExpr, body: TExpr)
  case TsWhile(label: Option[String], cond: TExpr, body: TExpr)
  case TsLoop(label: Option[String], body: TExpr)
  case TsInvariant(expr: TExpr)
}

/// A generic parameter of a declaration.  A value parameter has `valueTy`.
pub record TTypeParam {
  name: String
  bounds: List[Ty]
  valueTy: Option[Ty]
}

pub record TParamDecl {
  local: LocalDecl
  mode: TMode
  dflt: Option[TExpr]
}

/// A function or method with a body, ready to verify and lower.
pub record TFnDecl {
  sym: SymbolId
  typeParams: List[TTypeParam]
  params: List[TParamDecl]
  ret: Ty
  isAsync: Bool
  preconds: List[TExpr]
  postconds: List[TExpr]
  body: Option[TExpr]
  span: Span
  /// A protected entry's `when:` guard, a `Bool` over the receiver's fields and the entry's
  /// parameters.  The TIR carries no locks: backends lower locking and the wait from this.
  barrier: Option[TExpr] = None
}

/// A callable's signature, as a call checks against it.
pub record TSig {
  typeParamCount: Int
  params: List[TParamTy]
  ret: Ty
  isAsync: Bool
}

pub record TFieldSig {
  name: String
  ty: Ty
  mutable: Bool
}

pub union TSymKind {
  case TSkFunc
  case TSkType
  /// A union or enum case, constructed as `XConstruct`.
  case TSkCase
  case TSkVal
  case TSkConst
  case TSkInterfaceMethod
  /// An entry or `func` of a protected type: callable like a method, with the protected
  /// value as the first parameter and the lock taken by the backend (docs/70 §6.2).
  case TSkEntry
}

/// What the verifier needs to know about a declaration it meets: this
/// package's own, and every loaded interface's.  `sig` is present for a
/// callable and for a case (its payload as parameters, result the union);
/// `fields` for a record, an exposed record and a case.  `mutable` is for a
/// `var` global.
pub record TSymEntry {
  sym: SymbolId
  kind: TSymKind
  typeParamCount: Int
  sig: Option[TSig]
  fields: List[TFieldSig]
  ty: Option[Ty]
  mutable: Bool
}

pub record TPackage {
  name: String
  symbols: List[TSymEntry]
  funcs: List[TFnDecl]
}
