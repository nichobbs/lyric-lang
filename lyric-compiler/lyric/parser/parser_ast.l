//! parser_ast.l — AST type definitions for the self-hosted Lyric parser.
//! Mirrors compiler/src/Lyric.Parser/Ast.fs.  All types are pub so the
//! compiler pipeline can import Lyric.Parser and access them.
package Lyric.Parser

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// §1. Paths, visibility, doc-comments, annotations, literals.
// ─────────────────────────────────────────────────────────────────────────────
pub record ModulePath {
  segments: List[String]
  span: Span
}

/// Join module-path segments with `.` (e.g. `["Std", "Core"]` ->
/// `"Std.Core"`); an empty list yields `""`.
pub func modulePathJoin(segs: in List[String]): String {
  if segs.count == 0 {
    return ""
  }
  var s = segs[0]
  var i = 1
  while i < segs.count {
    s = s + "." + segs[i]
    i = i + 1
  }
  s
}

pub union Visibility {
  case VisPub(span: Span)
  case VisInternal(span: Span)
}

pub record DocComment {
  isModule: Bool
  text: String
  span: Span
}

pub union AnnotationValue {
  case AVInt(value: Long, span: Span)
  case AVString(value: String, span: Span)
  case AVBool(value: Bool, span: Span)
  case AVIdent(value: String, span: Span)
}

pub union AnnotationArg {
  case AAName(name: String, value: AnnotationValue, span: Span)
  case ABare(name: String, span: Span)
  case ALiteral(value: AnnotationValue, span: Span)
}

pub record Annotation {
  name: ModulePath
  args: List[AnnotationArg]
  span: Span
}

pub union Literal {
  // `raw` is the verbatim source spelling (e.g. `0xFF`, `100_000`,
  // `2.99`, `1i64`) so the formatter can round-trip it instead of
  // re-rendering the parsed value (which would canonicalise `0xFF` to
  // `255` and `2.99` to `2.9899999999999998`).  Empty for literals the
  // compiler synthesises (no source text).
  case LInt(value: Long, suffix: IntSuffix, raw: String)
  case LFloat(value: Double, suffix: FloatSuffix, raw: String)
  case LChar(codepoint: Int)
  case LString(text: String)
  case LTripleString(text: String)
  case LRawString(text: String)
  case LBool(value: Bool)
  case LUnit
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Type arguments and range bounds (forward-reference Expr).
  // ─────────────────────────────────────────────────────────────────────────────
}

pub union RangeBound {
  case RBClosed(lo: Expr, hi: Expr)
  case RBHalfOpen(lo: Expr, hi: Expr)
  case RBLowerOpen(hi: Expr)
  case RBUpperOpen(lo: Expr)
}

pub union TypeArg {
  case TAType(ty: TypeExpr)
  case TAValue(expr: Expr)
  // ─────────────────────────────────────────────────────────────────────────────
  // §3. Type expressions.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record TypeExpr {
  kind: TypeExprKind
  span: Span
}

pub union TypeExprKind {
  case TRef(path: ModulePath)
  case TGenericApp(head: ModulePath, args: List[TypeArg])
  case TArray(size: TypeArg, element: TypeExpr)
  case TSlice(element: TypeExpr)
  case TRefined(underlying: ModulePath, range: RangeBound)
  case TTuple(types: List[TypeExpr])
  case TNullable(inner: TypeExpr)
  case TFunction(parameters: List[TypeExpr], retTy: TypeExpr)
  case TUnit
  case TSelf
  case TNever
  case TParen(inner: TypeExpr)
  case TError
  // ─────────────────────────────────────────────────────────────────────────────
  // §4. Patterns.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub union RecordPatternField {
  case RPFNamed(name: String, pattern: Pattern, span: Span)
  case RPFShort(name: String, span: Span)
}

pub record Pattern {
  kind: PatternKind
  span: Span
}

pub union PatternKind {
  case PWildcard
  case PLiteral(lit: Literal)
  case PRange(lo: Expr, inclusive: Bool, hi: Expr)
  case PBinding(name: String, inner: Option[Pattern])
  case PConstructor(head: ModulePath, args: List[Pattern])
  case PRecord(head: ModulePath, fields: List[RecordPatternField], ignoreRest: Bool)
  case PTuple(patterns: List[Pattern])
  case PParen(inner: Pattern)
  case PTypeTest(inner: Pattern, ty: TypeExpr)
  case POr(patterns: List[Pattern])
  case PError
  // ─────────────────────────────────────────────────────────────────────────────
  // §5. Contracts.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record InvariantClause {
  expr: Expr
  span: Span
}

pub union ContractClause {
  case CCRequires(expr: Expr, span: Span)
  case CCEnsures(expr: Expr, span: Span)
  case CCWhen(expr: Expr, span: Span)
  case CCDecreases(expr: Expr, span: Span)
  case CCRaises(types: List[TypeExpr], span: Span)
  // ─────────────────────────────────────────────────────────────────────────────
  // §6. Generics, where-clauses, parameters.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record PropertyBinder {
  name: String
  ty: TypeExpr
  span: Span
}

pub record ConstraintRef {
  head: ModulePath
  args: List[TypeArg]
  span: Span
}

pub record WhereBound {
  name: String
  constraints: List[ConstraintRef]
  span: Span
}

pub record WhereClause {
  bounds: List[WhereBound]
  span: Span
}

pub union GenericParam {
  case GPType(name: String, span: Span)
  case GPValue(name: String, constraint: TypeExpr, span: Span)
}

pub record GenericParams {
  params: List[GenericParam]
  span: Span
}

pub union ParamMode {
  case PMIn
  case PMOut
  case PMInout
}

pub record Param {
  mode: ParamMode
  // `true` when the source wrote an explicit `in`/`out`/`inout` keyword.
  // Omitting the mode is sugar for `in`; this flag lets the formatter
  // round-trip the bare form instead of synthesising an `in`.
  modeExplicit: Bool
  name: String
  ty: TypeExpr
  dflt: Option[Expr]
  // Leading annotations written before the parameter name, e.g.
  // `@body req: in CreateRequest` (consumed by lyric-web's body binding).
  // The grammar's `Param` production carries `{ Annotation }` ahead of the
  // name; an omitted annotation list is the empty list.
  annotations: List[Annotation]
  span: Span
  // ─────────────────────────────────────────────────────────────────────────────
  // §7. Expressions.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub union PrefixOp {
  case PreNeg
  case PreNot
  case PreRef
}

pub union BinOp {
  case BAdd
  case BSub
  case BMul
  case BDiv
  case BMod
  case BAnd
  case BOr
  case BXor
  case BEq
  case BNeq
  case BLt
  case BLte
  case BGt
  case BGte
  case BCoalesce
  case BImplies
}

pub union AssignOp {
  case AssEq
  case AssPlus
  case AssMinus
  case AssStar
  case AssSlash
  case AssPercent
}

pub union ExprOrBlock {
  case EOBExpr(expr: Expr)
  case EOBBlock(block: Block)
}

pub union InterpolatedSegment {
  case ISText(text: String, span: Span)
  case ISExpr(expr: Expr)
}

pub union CallArg {
  case CANamed(name: String, value: Expr, span: Span)
  case CAPositional(expr: Expr)
}

pub record LambdaParam {
  name: String
  ty: Option[TypeExpr]
  span: Span
}

pub record MatchArm {
  pattern: Pattern
  guard: Option[Expr]
  body: ExprOrBlock
  span: Span
}

pub record Expr {
  kind: ExprKind
  span: Span
}

pub union ExprKind {
  case ELiteral(lit: Literal)
  case EInterpolated(segments: List[InterpolatedSegment])
  case EPath(path: ModulePath)
  case EParen(inner: Expr)
  case ETuple(exprs: List[Expr])
  case EList(exprs: List[Expr])
  case EIf(cond: Expr, thenBranch: ExprOrBlock, elseBranch: Option[ExprOrBlock], thenForm: Bool)
  case EMatch(scrutinee: Expr, arms: List[MatchArm])
  case EAwait(inner: Expr)
  case EYield(inner: Expr)
  case ESpawn(inner: Expr)
  case ETry(inner: Expr)
  case EOld(inner: Expr)
  case EForall(binders: List[PropertyBinder], whereExpr: Option[Expr], body: Expr)
  case EExists(binders: List[PropertyBinder], whereExpr: Option[Expr], body: Expr)
  case ESelf
  case EResult
  case ELambda(lambdaParams: List[LambdaParam], body: Block)
  case ECall(fn: Expr, args: List[CallArg])
  case ETypeApp(fn: Expr, args: List[TypeArg])
  case EIndex(receiver: Expr, indices: List[Expr])
  case EMember(receiver: Expr, memberName: String)
  case EPropagate(inner: Expr)
  case EPrefix(op: PrefixOp, operand: Expr)
  case EBinop(op: BinOp, lhs: Expr, rhs: Expr)
  case ERange(bound: RangeBound)
  case EAssign(target: Expr, op: AssignOp, value: Expr)
  case EBlock(block: Block)
  case EUnsafe(block: Block)
  case EError
  // ─────────────────────────────────────────────────────────────────────────────
  // §8. Blocks and statements.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record Block {
  statements: List[Statement]
  span: Span
}

pub union LocalBinding {
  case LBVal(pat: Pattern, ty: Option[TypeExpr], init: Expr)
  case LBVar(name: String, ty: Option[TypeExpr], init: Option[Expr])
  case LBLet(name: String, ty: Option[TypeExpr], init: Expr)
}

pub record CatchClause {
  typeName: String
  bindName: Option[String]
  body: Block
  span: Span
}

pub union StatementKind {
  case SLocal(binding: LocalBinding)
  case SAssign(target: Expr, op: AssignOp, value: Expr)
  case SReturn(value: Option[Expr])
  case SBreak(label: Option[String])
  case SContinue(label: Option[String])
  case SThrow(expr: Expr)
  case STry(body: Block, catches: List[CatchClause], finally_: Option[Block])
  case SDefer(body: Block)
  case SScope(binding: Option[String], body: Block)
  case SFor(label: Option[String], pat: Pattern, iter: Expr, body: Block)
  case SWhile(label: Option[String], cond: Expr, body: Block)
  case SLoop(label: Option[String], body: Block)
  case SInvariant(expr: Expr)
  case SExpr(expr: Expr)
  case SRule(lhs: Expr, rhs: Expr)
  case SItem(item: Item)
}

pub record Statement {
  kind: StatementKind
  span: Span
  // ─────────────────────────────────────────────────────────────────────────────
  // §9. Declaration types.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record FieldDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility: Option[Visibility]
  // `true` when the field was declared `var` (a mutable record/opaque field,
  // language reference §3.4).  Plain fields are immutable.
  isMutable: Bool
  name: String
  ty: TypeExpr
  dflt: Option[Expr]
  span: Span
}

pub union RecordMember {
  case RMField(field: FieldDecl)
  case RMInvariant(inv: InvariantClause)
  case RMFunc(fn: FunctionDecl)
}

pub record RecordDecl {
  name: String
  generics: Option[GenericParams]
  whereClause: Option[WhereClause]
  members: List[RecordMember]
  span: Span
}

pub union UnionField {
  case UFNamed(name: String, ty: TypeExpr, span: Span)
  case UFPos(ty: TypeExpr, span: Span)
}

pub record UnionCase {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name: String
  fields: List[UnionField]
  span: Span
}

pub record UnionDecl {
  name: String
  generics: Option[GenericParams]
  whereClause: Option[WhereClause]
  cases: List[UnionCase]
  span: Span
}

pub record EnumCase {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name: String
  span: Span
}

pub record EnumDecl {
  name: String
  cases: List[EnumCase]
  span: Span
}

pub union OpaqueMember {
  case OMField(field: FieldDecl)
  case OMInvariant(inv: InvariantClause)
}

pub record OpaqueTypeDecl {
  name: String
  generics: Option[GenericParams]
  whereClause: Option[WhereClause]
  annotations: List[Annotation]
  members: List[OpaqueMember]
  hasBody: Bool
  span: Span
}

pub union ProtectedField {
  case PFVar(name: String, ty: TypeExpr, init: Option[Expr], span: Span)
  case PFLet(name: String, ty: TypeExpr, init: Option[Expr], span: Span)
  case PFImmutable(field: FieldDecl)
}

pub union FunctionBody {
  case FBExpr(expr: Expr)
  case FBBlock(block: Block)
}

pub record FunctionDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility: Option[Visibility]
  isAsync: Bool
  name: String
  generics: Option[GenericParams]
  params: List[Param]
  ret: Option[TypeExpr]
  whereClause: Option[WhereClause]
  contracts: List[ContractClause]
  body: Option[FunctionBody]
  span: Span
}

pub record EntryDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility: Option[Visibility]
  name: String
  params: List[Param]
  ret: Option[TypeExpr]
  contracts: List[ContractClause]
  body: FunctionBody
  span: Span
}

pub union ProtectedMember {
  case PMField(field: ProtectedField)
  case PMInvariant(inv: InvariantClause)
  case PMEntry(entryDecl: EntryDecl)
  case PMFunc(fn: FunctionDecl)
}

pub record ProtectedTypeDecl {
  name: String
  generics: Option[GenericParams]
  whereClause: Option[WhereClause]
  members: List[ProtectedMember]
  span: Span
}

pub record TypeAliasDecl {
  name: String
  generics: Option[GenericParams]
  rhs: TypeExpr
  span: Span
}

pub record DistinctTypeDecl {
  name: String
  generics: Option[GenericParams]
  underlying: TypeExpr
  rangeClause: Option[RangeBound]
  derives: List[String]
  span: Span
}

pub record FunctionSig {
  // Doc comments on a body-less signature (interface method).  Extern
  // members carry their docs on the `ExternMemberDecl` wrapper instead, so
  // this is empty for `EMSig`.
  docComments: List[DocComment]
  isAsync: Bool
  name: String
  generics: Option[GenericParams]
  params: List[Param]
  ret: Option[TypeExpr]
  whereClause: Option[WhereClause]
  contracts: List[ContractClause]
  span: Span
}

pub record AssociatedTypeDecl {
  name: String
  dflt: Option[TypeExpr]
  span: Span
}

pub union InterfaceMember {
  case IMSig(sig: FunctionSig)
  case IMFunc(fn: FunctionDecl)
  case IMAssoc(assoc: AssociatedTypeDecl)
}

pub record InterfaceDecl {
  name: String
  generics: Option[GenericParams]
  whereClause: Option[WhereClause]
  members: List[InterfaceMember]
  span: Span
}

pub union ImplMember {
  case IMplFunc(fn: FunctionDecl)
  case IMplAssoc(assoc: AssociatedTypeDecl)
}

pub record ImplDecl {
  generics: Option[GenericParams]
  iface: ConstraintRef
  target: TypeExpr
  whereClause: Option[WhereClause]
  members: List[ImplMember]
  span: Span
}

pub union WireMember {
  case WMProvided(name: String, ty: TypeExpr, span: Span)
  case WMSingleton(name: String, ty: TypeExpr, init: Expr, span: Span)
  case WMScoped(scopeName: String, name: String, ty: TypeExpr, init: Expr, span: Span)
  case WMBind(iface: TypeExpr, provider: Expr, span: Span)
  case WMExpose(name: String, span: Span)
  case WMLocal(name: String, ty: Option[TypeExpr], init: Expr, span: Span)
}

pub record WireDecl {
  name: String
  params: List[Param]
  members: List[WireMember]
  span: Span
}

pub record ScopeKindDecl {
  name: String
  span: Span
}

pub union ExternMember {
  case EMRecord(decl: RecordDecl)
  case EMExposedRec(decl: RecordDecl)
  case EMUnion(decl: UnionDecl)
  case EMEnum(decl: EnumDecl)
  case EMOpaque(decl: OpaqueTypeDecl)
  case EMSig(sig: FunctionSig)
  case EMTypeAlias(decl: TypeAliasDecl)
  case EMDistinctType(decl: DistinctTypeDecl)
}

/// An extern-package member together with the leading doc comments,
/// annotations, and `pub`/`internal` visibility the source wrote in front
/// of it.  The bare `ExternMember` union carries only the declaration; the
/// surrounding metadata lives here so the formatter can round-trip it.
pub record ExternMemberDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility: Option[Visibility]
  kind: ExternMember
  span: Span
}

pub record ExternPackageDecl {
  path: ModulePath
  annotations: List[Annotation]
  members: List[ExternMemberDecl]
  span: Span
}

pub record ExternTypeDecl {
  name: String
  generics: Option[GenericParams]
  clrName: String
  span: Span
}

pub record TestDecl {
  title: String
  body: Block
  span: Span
}

pub record PropertyDecl {
  title: String
  forAll: List[PropertyBinder]
  guardExpr: Option[Expr]
  body: Block
  span: Span
}

pub record FixtureDecl {
  name: String
  nameSpan: Span
  ty: Option[TypeExpr]
  init: Expr
  span: Span
  // ─────────────────────────────────────────────────────────────────────────────
  // §10. Items.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record ConstDecl {
  name: String
  ty: TypeExpr
  init: Expr
  span: Span
}

pub record ValDecl {
  pattern: Pattern
  ty: Option[TypeExpr]
  init: Expr
  span: Span
}

pub union ItemKind {
  case IConst(decl: ConstDecl)
  case IVal(decl: ValDecl)
  case IFunc(decl: FunctionDecl)
  case ITypeAlias(decl: TypeAliasDecl)
  case IDistinctType(decl: DistinctTypeDecl)
  case IRecord(decl: RecordDecl)
  case IExposedRec(decl: RecordDecl)
  case IUnion(decl: UnionDecl)
  case IEnum(decl: EnumDecl)
  case IOpaque(decl: OpaqueTypeDecl)
  case IProtected(decl: ProtectedTypeDecl)
  case IInterface(decl: InterfaceDecl)
  case IImpl(decl: ImplDecl)
  case IWire(decl: WireDecl)
  case IScopeKind(decl: ScopeKindDecl)
  case IExtern(decl: ExternPackageDecl)
  case IExternType(decl: ExternTypeDecl)
  case ITest(decl: TestDecl)
  case IProperty(decl: PropertyDecl)
  case IFixture(decl: FixtureDecl)
  /// Module-scope `config Name { ... }` per `docs/25-config-blocks.md` (D046).
  case IConfig(decl: ConfigDecl)
  /// Module-scope `aspect Name { ... }` per `docs/26-aspects.md` (D047).
  case IAspect(decl: AspectDecl)
  case IError
}

/// One field inside a `config { ... }` block (D046).  `default` is
/// `None` for required fields (the runtime aborts at startup if the
/// env var is unset / unparseable); a literal default of the
/// declared type otherwise.
pub record ConfigField {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name: String
  ty: TypeExpr
  default: Option[Expr]
  span: Span
}

pub record ConfigDecl {
  name: String
  fields: List[ConfigField]
  span: Span
}

/// `matches:` predicate for D047 aspect blocks.  All predicates within
/// a `matches:` clause are AND'd; the `except name in { ... }` exclusion
/// list lives on AspectDecl.
pub union AspectMatcher {
  case AMNameLike(glob: String, span: Span)
  /// `name in { fn1, fn2 }` — matches when the function's short name is one
  /// of the listed identifiers (set membership).  The positive counterpart
  /// of the `except name in { … }` exclusion list.
  case AMNameIn(names: List[String], span: Span)
  case AMAnnotated(annotName: String, span: Span)
  case AMVisibility(vis: String, span: Span)
  case AMSignatureReturns(typeGlob: String, span: Span)
}

pub record AspectAround {
  argsName: String
  retName: Option[String]
  body: Block
  span: Span
}

pub record AspectDecl {
  name: String
  /// `from Pkg.Template` — present only on instantiation-form aspects (D051).
  from: Option[ModulePath]
  /// Anonymous `config { }` block inside the aspect body (D047/D051).
  config: List[ConfigField]
  /// Predicates that all must hold (AND) for a function to be matched.
  matches: List[AspectMatcher]
  /// Short names excluded from matching even when all predicates hold.
  exceptNames: List[String]
  around: Option[AspectAround]
  contracts: List[ContractClause]
  // §5 composition: requires:/ensures: on aspect body
  wraps: List[String]
  // §6 ordering: this aspect wraps the named aspects
  inside: List[String]
  // §6 ordering: this aspect runs inside the named aspects
  span: Span
  // D046 / D047 self-hosted parser dispatch + bodies are added in
  // `parser_items.l` alongside the AST shapes above.
}

pub record Item {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility: Option[Visibility]
  kind: ItemKind
  span: Span
  // ─────────────────────────────────────────────────────────────────────────────
  // §11. Imports and source file.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record ImportItem {
  name: String
  asAlias: Option[String]
  span: Span
}

pub union ImportSelector {
  case ISSingle(item: ImportItem)
  case ISGroup(items: List[ImportItem])
}

pub record ImportDecl {
  path: ModulePath
  selector: Option[ImportSelector]
  asAlias: Option[String]
  isPubUse: Bool
  span: Span
}

pub record PackageDecl {
  path: ModulePath
  span: Span
}

pub record SourceFile {
  moduleDoc: List[DocComment]
  fileAnnotations: List[Annotation]
  packageDecl: PackageDecl
  imports: List[ImportDecl]
  items: List[Item]
  span: Span
}

pub record ParseResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
  /// Concrete syntax tree — lossless red/green representation that
  /// preserves every byte of the original source (including comments
  /// and whitespace).  Built alongside the AST; downstream consumers
  /// that only care about semantics can ignore it, while a formatter
  /// or LSP walks it to render or refactor without losing trivia.
  /// See `parser_cst.l` for the data model and `nodeSourceText` for
  /// byte-faithful reconstruction.
  cst: GreenNode
  /// Original source string (post CR/LF normalisation by `lex`).
  /// Carried alongside the CST so callers can render token text via
  /// `tokenSourceText` / `nodeSourceText` without retaining the file
  /// contents themselves.
  source: String
}

// ─────────────────────────────────────────────────────────────────────────────
// §X. Same-package Option constructors for cross-package rewriters.
// ─────────────────────────────────────────────────────────────────────────────
/// Build `Some(around)` inside the declaring package.  The stage-0
/// bootstrap emitter miscompiles `Option[AspectAround]` construction in a
/// *third* package (e.g. `Lyric.AliasRewriter`): the resulting value
/// matches neither `Some` nor `None` in consuming packages, so an aspect
/// rebuilt by such a rewriter silently loses its `around` body and the
/// weaver stops matching it (#1298 investigation).  Routing the
/// construction through this helper keeps the generic instantiation in
/// `Lyric.Parser`, where the parser's own construction is known-good.
pub func someAspectAround(a: in AspectAround): Option[AspectAround] {
  Some(value = a)
}
