// lyric/ast.l — self-hosted Lyric AST type declarations (Phase 5 §M5.1).
//
// Mirrors the F# parser AST at compiler/src/Lyric.Parser/Ast.fs.
// All types are public so the self-hosted parser (Lyric.Parser) and
// downstream passes (type checker, emitter, verifier) can import this
// package and share a single definition.
//
// Naming conventions mirror the F# source:
//   TypeExprKind variants: T prefix
//   PatternKind variants:  P prefix
//   ExprKind variants:     E prefix
//   StatementKind variants:S prefix
//   ItemKind variants:     I prefix
//   (others carry the same short prefix as the F# original)
//
// Fields named after Lyric keywords are renamed:
//   F# `Type`      -> `ty`
//   F# `Return`    -> `returnTy`
//   F# `Where`     -> `whereClause`
//   F# `Interface` -> `iface`
package Lyric.Ast

import Lyric.Lexer
import Std.Core
import Std.Collections


// ─────────────────────────────────────────────────────────────────────────────
// §1. Core: paths, visibility, doc-comments, annotations, literals.
// ─────────────────────────────────────────────────────────────────────────────

/// A dotted module/qualifier path, e.g. `Money.Amount`.
@stable(since="0.1")
pub record ModulePath {
  segments: List[String]
  span:     Span
}

/// Visibility modifier on an item or field.  Absent visibility is
/// package-private.
@stable(since="0.1")
pub union Visibility {
  case VisPub(span: Span)
  case VisInternal(span: Span)
}

/// A `///` or `//!` doc comment.
@stable(since="0.1")
pub record DocComment {
  isModule: Bool
  text:     String
  span:     Span
}

/// Argument inside an annotation.
@stable(since="0.1")
pub union AnnotationArg {
  case AAName(name: String, value: AnnotationValue, span: Span)
  case ABare(name: String, span: Span)
  case ALiteral(value: AnnotationValue, span: Span)
}

/// A literal value admissible inside an annotation.
@stable(since="0.1")
pub union AnnotationValue {
  case AVInt(value: Long, span: Span)
  case AVString(value: String, span: Span)
  case AVBool(value: Bool, span: Span)
  case AVIdent(value: String, span: Span)
}

@stable(since="0.1")
pub record Annotation {
  name: ModulePath
  args: List[AnnotationArg]
  span: Span
}

/// A literal in expression position.
@stable(since="0.1")
pub union Literal {
  case LInt(value: Long, suffix: IntSuffix)
  case LFloat(value: Double, suffix: FloatSuffix)
  case LChar(codepoint: Int)
  case LString(text: String)
  case LTripleString(text: String)
  case LRawString(text: String)
  case LBool(value: Bool)
  case LUnit
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. Type expressions.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record TypeExpr {
  kind: TypeExprKind
  span: Span
}

@stable(since="0.1")
pub union TypeExprKind {
  /// A bare named type, possibly qualified (`Money.Amount`).
  case TRef(path: ModulePath)
  /// `Result[Amount, ContractViolation]`.
  case TGenericApp(head: ModulePath, args: List[TypeArg])
  /// `array[N, T]` — fixed-size array.
  case TArray(size: TypeArg, element: TypeExpr)
  /// `slice[T]` — dynamic slice.
  case TSlice(element: TypeExpr)
  /// `Int range a ..= b` — anonymous range subtype.
  case TRefined(underlying: ModulePath, range: RangeBound)
  /// `(A, B)` — tuple type.
  case TTuple(elements: List[TypeExpr])
  /// `T?` — nullable.
  case TNullable(inner: TypeExpr)
  /// `(A, B) -> C` — function type.
  case TFunction(parameters: List[TypeExpr], resultTy: TypeExpr)
  case TUnit
  case TSelf
  case TNever
  /// `(T)` — explicit parens preserved for source fidelity.
  case TParen(inner: TypeExpr)
  case TError
}

/// A type argument inside `[…]`.
@stable(since="0.1")
pub union TypeArg {
  case TAType(ty: TypeExpr)
  case TAValue(expr: Expr)
}

/// Bounds of a `range` clause.
@stable(since="0.1")
pub union RangeBound {
  case RBClosed(lo: Expr, hi: Expr)
  case RBHalfOpen(lo: Expr, hi: Expr)
  case RBLowerOpen(hi: Expr)
  case RBUpperOpen(lo: Expr)
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. Patterns.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Pattern {
  kind: PatternKind
  span: Span
}

@stable(since="0.1")
pub union PatternKind {
  case PWildcard
  case PLiteral(lit: Literal)
  case PRange(lo: Expr, inclusive: Bool, hi: Expr)
  case PBinding(name: String, inner: Option[Pattern])
  case PConstructor(head: ModulePath, args: List[Pattern])
  case PRecord(head: ModulePath, fields: List[RecordPatternField], ignoreRest: Bool)
  case PTuple(elements: List[Pattern])
  case PParen(inner: Pattern)
  case PTypeTest(inner: Pattern, ty: TypeExpr)
  case POr(alternatives: List[Pattern])
  case PError
}

@stable(since="0.1")
pub union RecordPatternField {
  case RPFNamed(name: String, pattern: Pattern, span: Span)
  case RPFShort(name: String, span: Span)
}


// ─────────────────────────────────────────────────────────────────────────────
// §4. Contracts.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union ContractClause {
  case CCRequires(expr: Expr, span: Span)
  case CCEnsures(expr: Expr, span: Span)
  case CCWhen(expr: Expr, span: Span)
  case CCDecreases(expr: Expr, span: Span)
  case CCRaises(types: List[TypeExpr], span: Span)
}

/// `invariant: …` clause on a type body.
@stable(since="0.1")
pub record InvariantClause {
  expr: Expr
  span: Span
}

/// Contract expressions reuse the full Expr grammar; the alias
/// documents the intent without adding a distinct type.
@stable(since="0.1")
pub alias ContractExpr = Expr


// ─────────────────────────────────────────────────────────────────────────────
// §5. Generics, parameters, where-clauses.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union GenericParam {
  case GPType(name: String, span: Span)
  /// `N: Nat` value generic.
  case GPValue(name: String, constraint: TypeExpr, span: Span)
}

@stable(since="0.1")
pub record GenericParams {
  params: List[GenericParam]
  span:   Span
}

@stable(since="0.1")
pub record ConstraintRef {
  head: ModulePath
  args: List[TypeArg]
  span: Span
}

/// `where T: Compare + Hash` bound.
@stable(since="0.1")
pub record WhereBound {
  name:        String
  constraints: List[ConstraintRef]
  span:        Span
}

@stable(since="0.1")
pub record WhereClause {
  bounds: List[WhereBound]
  span:   Span
}

@stable(since="0.1")
pub union ParamMode {
  case PMIn
  case PMOut
  case PMInout
}

@stable(since="0.1")
pub record Param {
  mode:    ParamMode
  name:    String
  ty:      TypeExpr
  default: Option[Expr]
  span:    Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §6. Item-shaped declarations.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record FieldDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility:  Option[Visibility]
  name:        String
  ty:          TypeExpr
  default:     Option[Expr]
  span:        Span
}

@stable(since="0.1")
pub union RecordMember {
  case RMField(field: FieldDecl)
  case RMInvariant(clause: InvariantClause)
  /// Method inside a record body; hoisted to UFCS by the parser after
  /// the file finishes parsing.
  case RMFunc(funcDecl: FunctionDecl)
}

@stable(since="0.1")
pub record RecordDecl {
  name:        String
  generics:    Option[GenericParams]
  whereClause: Option[WhereClause]
  members:     List[RecordMember]
  span:        Span
}

/// Structurally identical to RecordDecl; tagged separately by ItemKind.
@stable(since="0.1")
pub alias ExposedRecordDecl = RecordDecl

@stable(since="0.1")
pub union UnionField {
  case UFNamed(name: String, ty: TypeExpr, span: Span)
  case UFPos(ty: TypeExpr, span: Span)
}

@stable(since="0.1")
pub record UnionCase {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name:        String
  fields:      List[UnionField]
  span:        Span
}

@stable(since="0.1")
pub record UnionDecl {
  name:        String
  generics:    Option[GenericParams]
  whereClause: Option[WhereClause]
  cases:       List[UnionCase]
  span:        Span
}

@stable(since="0.1")
pub record EnumCase {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name:        String
  span:        Span
}

@stable(since="0.1")
pub record EnumDecl {
  name:  String
  cases: List[EnumCase]
  span:  Span
}

@stable(since="0.1")
pub union OpaqueMember {
  case OMField(field: FieldDecl)
  case OMInvariant(clause: InvariantClause)
}

@stable(since="0.1")
pub record OpaqueTypeDecl {
  name:        String
  generics:    Option[GenericParams]
  whereClause: Option[WhereClause]
  annotations: List[Annotation]
  members:     List[OpaqueMember]
  hasBody:     Bool
  span:        Span
}

@stable(since="0.1")
pub union ProtectedField {
  case PFVar(name: String, ty: TypeExpr, init: Option[Expr], span: Span)
  case PFLet(name: String, ty: TypeExpr, init: Option[Expr], span: Span)
  case PFImmutable(field: FieldDecl)
}

@stable(since="0.1")
pub union ProtectedMember {
  case PMField(field: ProtectedField)
  case PMInvariant(clause: InvariantClause)
  case PMEntry(entryDecl: EntryDecl)
  case PMFunc(funcDecl: FunctionDecl)
}

@stable(since="0.1")
pub record EntryDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility:  Option[Visibility]
  name:        String
  params:      List[Param]
  returnTy:    Option[TypeExpr]
  contracts:   List[ContractClause]
  body:        FunctionBody
  span:        Span
}

@stable(since="0.1")
pub record ProtectedTypeDecl {
  name:        String
  generics:    Option[GenericParams]
  whereClause: Option[WhereClause]
  members:     List[ProtectedMember]
  span:        Span
}

@stable(since="0.1")
pub record TypeAliasDecl {
  name:     String
  generics: Option[GenericParams]
  rhs:      TypeExpr
  span:     Span
}

@stable(since="0.1")
pub record DistinctTypeDecl {
  name:       String
  generics:   Option[GenericParams]
  underlying: TypeExpr
  bounds:     Option[RangeBound]
  derives:    List[String]
  span:       Span
}

@stable(since="0.1")
pub union FunctionBody {
  /// `= expr` form.
  case FBExpr(expr: Expr)
  case FBBlock(body: Block)
}

@stable(since="0.1")
pub record FunctionDecl {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility:  Option[Visibility]
  isAsync:     Bool
  name:        String
  generics:    Option[GenericParams]
  params:      List[Param]
  returnTy:    Option[TypeExpr]
  whereClause: Option[WhereClause]
  contracts:   List[ContractClause]
  /// None for signatures and extern declarations.
  body:        Option[FunctionBody]
  span:        Span
}

@stable(since="0.1")
pub record FunctionSig {
  isAsync:     Bool
  name:        String
  generics:    Option[GenericParams]
  params:      List[Param]
  returnTy:    Option[TypeExpr]
  whereClause: Option[WhereClause]
  contracts:   List[ContractClause]
  span:        Span
}

@stable(since="0.1")
pub record AssociatedTypeDecl {
  name:    String
  default: Option[TypeExpr]
  span:    Span
}

@stable(since="0.1")
pub union InterfaceMember {
  case IMSig(sig: FunctionSig)
  /// Default method implementation.
  case IMFunc(funcDecl: FunctionDecl)
  case IMAssoc(assoc: AssociatedTypeDecl)
}

@stable(since="0.1")
pub record InterfaceDecl {
  name:        String
  generics:    Option[GenericParams]
  whereClause: Option[WhereClause]
  members:     List[InterfaceMember]
  span:        Span
}

@stable(since="0.1")
pub union ImplMember {
  case IMplFunc(funcDecl: FunctionDecl)
  case IMplAssoc(assoc: AssociatedTypeDecl)
}

@stable(since="0.1")
pub record ImplDecl {
  generics:    Option[GenericParams]
  iface:       ConstraintRef
  target:      TypeExpr
  whereClause: Option[WhereClause]
  members:     List[ImplMember]
  span:        Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §7. Wire blocks, user scopes, extern packages.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union WireMember {
  case WMProvided(name: String, ty: TypeExpr, span: Span)
  case WMSingleton(name: String, ty: TypeExpr, init: Expr, span: Span)
  case WMScoped(scopeKind: String, name: String, ty: TypeExpr, init: Expr, span: Span)
  case WMBind(iface: TypeExpr, provider: Expr, span: Span)
  case WMExpose(name: String, span: Span)
  case WMLocal(name: String, ty: Option[TypeExpr], init: Expr, span: Span)
}

@stable(since="0.1")
pub record WireDecl {
  name:    String
  params:  List[Param]
  members: List[WireMember]
  span:    Span
}

@stable(since="0.1")
pub record ScopeKindDecl {
  name: String
  span: Span
}

@stable(since="0.1")
pub union ExternMember {
  case EMRecord(decl: RecordDecl)
  case EMExposedRec(decl: ExposedRecordDecl)
  case EMUnion(decl: UnionDecl)
  case EMEnum(decl: EnumDecl)
  case EMOpaque(decl: OpaqueTypeDecl)
  case EMSig(sig: FunctionSig)
  case EMTypeAlias(decl: TypeAliasDecl)
  case EMDistinctType(decl: DistinctTypeDecl)
}

@stable(since="0.1")
pub record ExternPackageDecl {
  path:        ModulePath
  annotations: List[Annotation]
  members:     List[ExternMember]
  span:        Span
}

/// `extern type Foo = "System.Foo"` — Lyric-side alias for a CLR type.
@stable(since="0.1")
pub record ExternTypeDecl {
  name:     String
  generics: Option[GenericParams]
  clrName:  String
  span:     Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §8. Test items.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record TestDecl {
  title: String
  body:  Block
  span:  Span
}

@stable(since="0.1")
pub record PropertyBinder {
  name: String
  ty:   TypeExpr
  span: Span
}

@stable(since="0.1")
pub record PropertyDecl {
  title:  String
  forAll: List[PropertyBinder]
  guard:  Option[Expr]
  body:   Block
  span:   Span
}

@stable(since="0.1")
pub record FixtureDecl {
  name: String
  ty:   Option[TypeExpr]
  init: Expr
  span: Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §9. Expressions.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Expr {
  kind: ExprKind
  span: Span
}

@stable(since="0.1")
pub union ExprKind {
  case ELiteral(lit: Literal)
  case EInterpolated(segments: List[InterpolatedSegment])
  case EPath(path: ModulePath)
  /// `(e)` — explicit parenthesisation.
  case EParen(inner: Expr)
  /// `(a, b)` — tuple literal.
  case ETuple(elements: List[Expr])
  /// `[a, b, c]` — list literal.
  case EList(elements: List[Expr])
  /// `if cond then a else b` (thenForm=true) or `if cond { … } [else { … }]`.
  case EIf(cond: Expr, thenBranch: ExprOrBlock, elseBranch: Option[ExprOrBlock], thenForm: Bool)
  case EMatch(scrutinee: Expr, arms: List[MatchArm])
  case EAwait(inner: Expr)
  case ESpawn(inner: Expr)
  /// `try e` — expression form returning a Result-shaped value.
  case ETry(inner: Expr)
  /// `old(e)` — only valid inside ensures clauses.
  case EOld(inner: Expr)
  case EForall(binders: List[PropertyBinder], guard: Option[Expr], body: Expr)
  case EExists(binders: List[PropertyBinder], guard: Option[Expr], body: Expr)
  case ESelf
  /// `result` — only valid inside ensures clauses.
  case EResult
  case ELambda(params: List[LambdaParam], body: Block)
  case ECall(fn: Expr, args: List[CallArg])
  /// `f[A, B]` — explicit type-argument application.
  case ETypeApp(fn: Expr, args: List[TypeArg])
  /// `a[i]` — indexing.
  case EIndex(receiver: Expr, indices: List[Expr])
  case EMember(receiver: Expr, name: String)
  /// `e?` — error propagation.
  case EPropagate(inner: Expr)
  case EPrefix(op: PrefixOp, operand: Expr)
  case EBinop(op: BinOp, lhs: Expr, rhs: Expr)
  case ERange(bound: RangeBound)
  case EAssign(target: Expr, op: AssignOp, value: Expr)
  case EBlock(body: Block)
  /// `unsafe { … }` — opaque to the VC generator.
  case EUnsafe(body: Block)
  case EError
}

@stable(since="0.1")
pub union ExprOrBlock {
  case EOBExpr(expr: Expr)
  case EOBBlock(body: Block)
}

@stable(since="0.1")
pub union InterpolatedSegment {
  case ISText(text: String, span: Span)
  case ISExpr(expr: Expr)
}

@stable(since="0.1")
pub union CallArg {
  case CANamed(name: String, value: Expr, span: Span)
  case CAPositional(expr: Expr)
}

@stable(since="0.1")
pub record LambdaParam {
  name: String
  ty:   Option[TypeExpr]
  span: Span
}

@stable(since="0.1")
pub record MatchArm {
  pattern: Pattern
  guard:   Option[Expr]
  body:    ExprOrBlock
  span:    Span
}

@stable(since="0.1")
pub union PrefixOp {
  case PreNeg
  case PreNot
  case PreRef
}

@stable(since="0.1")
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
  /// `implies` — contract sub-language only.
  case BImplies
}

@stable(since="0.1")
pub union AssignOp {
  case AssEq
  case AssPlus
  case AssMinus
  case AssStar
  case AssSlash
  case AssPercent
}


// ─────────────────────────────────────────────────────────────────────────────
// §10. Statements and blocks.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Block {
  statements: List[Statement]
  span:       Span
}

@stable(since="0.1")
pub record Statement {
  kind: StatementKind
  span: Span
}

@stable(since="0.1")
pub union StatementKind {
  case SLocal(binding: LocalBinding)
  case SAssign(target: Expr, op: AssignOp, value: Expr)
  case SReturn(value: Option[Expr])
  case SBreak(label: Option[String])
  case SContinue(label: Option[String])
  case SThrow(value: Expr)
  case STry(body: Block, catches: List[CatchClause])
  case SDefer(body: Block)
  case SScope(binding: Option[String], body: Block)
  case SFor(label: Option[String], pat: Pattern, iter: Expr, body: Block)
  case SWhile(label: Option[String], cond: Expr, body: Block)
  case SLoop(label: Option[String], body: Block)
  /// `invariant: φ` — treated as a no-op by all passes except the verifier.
  case SInvariant(expr: Expr)
  case SExpr(expr: Expr)
  /// `lhs -> rhs` — stub-builder DSL rule; valid only inside a stub lambda.
  case SRule(lhs: Expr, rhs: Expr)
  case SItem(item: Item)
}

@stable(since="0.1")
pub union LocalBinding {
  case LBVal(pat: Pattern, ty: Option[TypeExpr], init: Expr)
  case LBVar(name: String, ty: Option[TypeExpr], init: Option[Expr])
  case LBLet(name: String, ty: Option[TypeExpr], init: Expr)
}

@stable(since="0.1")
pub record CatchClause {
  ty:      String
  bindAs:  Option[String]
  body:    Block
  span:    Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §11. Items (top-level declarations).
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Item {
  docComments: List[DocComment]
  annotations: List[Annotation]
  visibility:  Option[Visibility]
  kind:        ItemKind
  span:        Span
}

@stable(since="0.1")
pub union ItemKind {
  case IConst(decl: ConstDecl)
  case IVal(decl: ValDecl)
  case IFunc(decl: FunctionDecl)
  case ITypeAlias(decl: TypeAliasDecl)
  case IDistinctType(decl: DistinctTypeDecl)
  case IRecord(decl: RecordDecl)
  case IExposedRec(decl: ExposedRecordDecl)
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

@stable(since="0.1")
pub record ConfigField {
  docComments: List[DocComment]
  annotations: List[Annotation]
  name:        String
  ty:          TypeExpr
  /// `None` for required fields (process aborts at startup if env
  /// var is unset).  `Some(expr)` accepts a literal default of the
  /// declared field type.
  default:     Option[Expr]
  span:        Span
}

@stable(since="0.1")
pub record ConfigDecl {
  name:   String
  fields: List[ConfigField]
  span:   Span
}

@stable(since="0.1")
pub union AspectMatcher {
  /// `matches: name like "<glob>"` — single positive predicate
  /// supported in v1 of D047.
  case AMNameLike(glob: String, span: Span)
}

@stable(since="0.1")
pub record AspectAround {
  argsName: String
  retName:  Option[String]
  body:     Block
  span:     Span
}

@stable(since="0.1")
pub record AspectDecl {
  name:    String
  matches: List[AspectMatcher]
  around:  Option[AspectAround]
  span:    Span
}

@stable(since="0.1")
pub record ConstDecl {
  name: String
  ty:   TypeExpr
  init: Expr
  span: Span
}

@stable(since="0.1")
pub record ValDecl {
  pattern: Pattern
  ty:      Option[TypeExpr]
  init:    Expr
  span:    Span
}


// ─────────────────────────────────────────────────────────────────────────────
// §12. Imports and source file.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record ImportItem {
  name:    String
  aliasAs: Option[String]
  span:    Span
}

@stable(since="0.1")
pub union ImportSelector {
  /// `import Time.Instant [as Inst]`.
  case ISSingle(item: ImportItem)
  /// `import Money.{Amount, Cents [as C]}`.
  case ISGroup(items: List[ImportItem])
}

@stable(since="0.1")
pub record ImportDecl {
  path:     ModulePath
  selector: Option[ImportSelector]
  aliasAs:  Option[String]
  isPubUse: Bool
  span:     Span
}

@stable(since="0.1")
pub record PackageDecl {
  path: ModulePath
  span: Span
}

@stable(since="0.1")
pub record SourceFile {
  moduleDoc:            List[DocComment]
  fileLevelAnnotations: List[Annotation]
  packageDecl:          PackageDecl
  imports:              List[ImportDecl]
  items:                List[Item]
  span:                 Span
}
