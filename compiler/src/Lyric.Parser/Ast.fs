/// Parser-level abstract syntax tree for Lyric, mirroring the
/// non-terminals of docs/grammar.ebnf.
///
/// Conventions
/// -----------
/// * Most nodes are records of the shape `{ Kind: …Kind; Span: Span }`.
///   The `…Kind` discriminated union enumerates the variants; the
///   wrapper carries source-location data.
/// * A few small nodes (paths, literals) skip the wrapper and embed a
///   `Span` directly on each variant. The choice is per category and
///   noted at the type definition.
/// * Every category that can be produced from broken input includes an
///   `…Error` variant so the parser can keep going past a recoverable
///   syntax error and downstream passes can see a well-typed tree.
namespace Lyric.Parser.Ast

open Lyric.Lexer


// ---------------------------------------------------------------------------
// §1. Core: paths, visibility, doc-comments, annotations, literals.
// ---------------------------------------------------------------------------

/// A dotted module/qualifier path, e.g. `Money.Amount`, `std.collections`.
type ModulePath =
    { Segments: string list
      Span:     Span }

/// `pub` modifier on an item or field. Absent visibility is package-private.
type Visibility =
    | Pub of Span

/// A `///` or `//!` doc comment. The `IsModule` flag distinguishes the
/// two forms; payload is the comment text without the leading slashes.
type DocComment =
    { IsModule: bool
      Text:     string
      Span:     Span }

/// Argument inside an annotation: either a named binding (`name = value`),
/// a bare identifier, or a literal.
type AnnotationArg =
    | AAName     of name: string * value: AnnotationValue * Span
    | ABare      of name: string * Span
    | ALiteral   of value: AnnotationValue * Span

/// A literal value admissible inside an annotation.
and AnnotationValue =
    | AVInt    of value: uint64 * Span
    | AVString of value: string * Span
    | AVBool   of value: bool   * Span
    | AVIdent  of value: string * Span

type Annotation =
    { Name: ModulePath
      Args: AnnotationArg list
      Span: Span }

/// A literal in expression position. Mirrors Lyric.Lexer.Token's literal
/// variants but is a parser-domain type so downstream passes need not
/// depend on lexer internals.
type Literal =
    | LInt          of value: uint64 * suffix: IntSuffix
    | LFloat        of value: double * suffix: FloatSuffix
    | LChar         of int
    | LString       of string
    | LTripleString of string
    | LRawString    of string
    | LBool         of bool
    | LUnit


// ---------------------------------------------------------------------------
// §2. Type expressions.
//
// A `TypeExpr` is anything that can appear to the right of `:` in a
// binding, a parameter, or a type-argument position. Nullable, function,
// tuple, refined, array/slice, generic application — all live here.
// ---------------------------------------------------------------------------

type TypeExpr =
    { Kind: TypeExprKind
      Span: Span }

and TypeExprKind =
    /// A bare named type, possibly qualified (`Money.Amount`).
    | TRef of ModulePath

    /// A generic application like `Result[Amount, ContractViolation]`.
    | TGenericApp of head: ModulePath * args: TypeArg list

    /// `array[N, T]` — fixed-size array.
    | TArray of size: TypeArg * element: TypeExpr

    /// `slice[T]` — dynamic slice.
    | TSlice of TypeExpr

    /// `Int range a ..= b` use-site refinement (anonymous range subtype).
    | TRefined of underlying: ModulePath * range: RangeBound

    /// `(A, B)` — tuple type.
    | TTuple of TypeExpr list

    /// `T?` — nullable.
    | TNullable of TypeExpr

    /// `(A, B) -> C` — function type.
    | TFunction of parameters: TypeExpr list * result: TypeExpr

    /// `()` — the unit type.
    | TUnit

    /// `Self` — the self-type token used inside an interface/impl.
    | TSelf

    /// `Never` — uninhabited type.
    | TNever

    /// `(T)` — explicit parens preserved for source fidelity.
    | TParen of TypeExpr

    /// Recovery hatch when the parser couldn't make sense of the input.
    | TError

/// A type argument inside `[...]`. Mostly types, but value generics
/// admit constant expressions (handled by `TAValue`).
and TypeArg =
    | TAType  of TypeExpr
    | TAValue of Expr

/// A `range` clause's bounds. Both sides are expressions; the parser
/// makes no judgement about constancy here, that's a later pass.
and RangeBound =
    | RBClosed   of lo: Expr * hi: Expr           // a ..= b
    | RBHalfOpen of lo: Expr * hi: Expr           // a ..< b  (or  a .. b )
    | RBLowerOpen of hi: Expr                     // ..= b
    | RBUpperOpen of lo: Expr                     // a ..

// (Expr is defined in §6 below; F# resolves the forward reference via
// the mutual-recursion graph that follows from the `and`-chain.)


// ---------------------------------------------------------------------------
// §3. Patterns (used in match arms, val/var bindings, for loops).
// ---------------------------------------------------------------------------

and Pattern =
    { Kind: PatternKind
      Span: Span }

and PatternKind =
    | PWildcard
    | PLiteral     of Literal
    | PRange       of lo: Expr * inclusive: bool * hi: Expr
    | PBinding     of name: string * inner: Pattern option
    | PConstructor of head: ModulePath * args: Pattern list
    | PRecord      of head: ModulePath * fields: RecordPatternField list * ignoreRest: bool
    | PTuple       of Pattern list
    | PParen       of Pattern
    | PTypeTest    of inner: Pattern * ty: TypeExpr
    | POr          of Pattern list
    | PError

and RecordPatternField =
    | RPFNamed of name: string * pattern: Pattern * Span
    | RPFShort of name: string * Span


// ---------------------------------------------------------------------------
// §4. Contracts (requires/ensures/when/invariant/where-decreases/where-raises).
// ---------------------------------------------------------------------------

and ContractClause =
    | CCRequires  of ContractExpr * Span
    | CCEnsures   of ContractExpr * Span
    | CCWhen      of ContractExpr * Span
    | CCDecreases of ContractExpr * Span
    | CCRaises    of TypeExpr list * Span

/// `invariant: …` on a record / opaque / protected type body. Stored
/// separately from `RecordMember` because its structure differs from
/// a field declaration.
and InvariantClause =
    { Expr: ContractExpr
      Span: Span }

/// A contract expression syntactically reuses the full Expr grammar.
/// The §4.4 contract validator walks the expression and rejects
/// constructs outside the contract sub-language at a later stage.
and ContractExpr = Expr


// ---------------------------------------------------------------------------
// §5. Generics, parameters, where-clauses.
// ---------------------------------------------------------------------------

and GenericParam =
    | GPType  of name: string * Span
    /// `N: Nat`-style value generic. `Constraint` is the underlying type.
    | GPValue of name: string * constraint': TypeExpr * Span

and GenericParams =
    { Params: GenericParam list
      Span:   Span }

/// `where T: Compare + Hash` style bound.
and WhereBound =
    { Name:        string
      Constraints: ConstraintRef list
      Span:        Span }

and ConstraintRef =
    { Head: ModulePath
      Args: TypeArg list
      Span: Span }

and WhereClause =
    { Bounds: WhereBound list
      Span:   Span }

/// Function/entry parameter.
and Param =
    { Mode:    ParamMode
      Name:    string
      Type:    TypeExpr
      Default: Expr option
      Span:    Span }

and ParamMode = PMIn | PMOut | PMInout


// ---------------------------------------------------------------------------
// §6. Item-shaped declarations.
//
// Each top-level item (record, function, interface, …) has its own
// declaration record carrying name, optional generics/where, body, and
// span. The Item DU below tags one of these per item kind.
// ---------------------------------------------------------------------------

and FieldDecl =
    { DocComments: DocComment list
      Annotations: Annotation list
      Visibility:  Visibility option
      Name:        string
      Type:        TypeExpr
      Default:     Expr option
      Span:        Span }

and RecordMember =
    | RMField     of FieldDecl
    | RMInvariant of InvariantClause
    /// Method declared inside a record body (D037).  The parser hoists
    /// these to top-level UFCS-style `<RecordName>.<methodName>`
    /// functions after the source file finishes parsing; they're
    /// represented as `RMFunc` only for the duration of the AST.
    | RMFunc      of FunctionDecl

and RecordDecl =
    { Name:     string
      Generics: GenericParams option
      Where:    WhereClause option
      Members:  RecordMember list
      Span:     Span }

and ExposedRecordDecl = RecordDecl   // structurally identical; tagged by Item

and UnionField =
    | UFNamed of name: string * ty: TypeExpr * Span
    | UFPos   of TypeExpr * Span

and UnionCase =
    { DocComments: DocComment list
      Annotations: Annotation list
      Name:        string
      Fields:      UnionField list
      Span:        Span }

and UnionDecl =
    { Name:     string
      Generics: GenericParams option
      Where:    WhereClause option
      Cases:    UnionCase list
      Span:     Span }

and EnumCase =
    { DocComments: DocComment list
      Annotations: Annotation list
      Name:        string
      Span:        Span }

and EnumDecl =
    { Name:  string
      Cases: EnumCase list
      Span:  Span }

and OpaqueMember =
    | OMField     of FieldDecl
    | OMInvariant of InvariantClause

and OpaqueTypeDecl =
    { Name:        string
      Generics:    GenericParams option
      Where:       WhereClause option
      Annotations: Annotation list   // e.g. @projectable
      Members:     OpaqueMember list // empty when no body provided
      HasBody:     bool
      Span:        Span }

and ProtectedField =
    | PFVar       of name: string * ty: TypeExpr * init: Expr option * Span
    | PFLet       of name: string * ty: TypeExpr * init: Expr option * Span
    | PFImmutable of FieldDecl

and ProtectedMember =
    | PMField     of ProtectedField
    | PMInvariant of InvariantClause
    | PMEntry     of EntryDecl
    | PMFunc      of FunctionDecl

and EntryDecl =
    { DocComments: DocComment list
      Annotations: Annotation list
      Visibility:  Visibility option
      Name:        string
      Params:      Param list
      Return:      TypeExpr option
      Contracts:   ContractClause list
      Body:        FunctionBody
      Span:        Span }

and ProtectedTypeDecl =
    { Name:     string
      Generics: GenericParams option
      Where:    WhereClause option
      Members:  ProtectedMember list
      Span:     Span }

and TypeAliasDecl =
    { Name:     string
      Generics: GenericParams option
      RHS:      TypeExpr
      Span:     Span }

and DistinctTypeDecl =
    { Name:     string
      Generics: GenericParams option
      Underlying: TypeExpr
      Range:    RangeBound option
      Derives:  string list                         // marker names
      Span:     Span }

and FunctionBody =
    | FBExpr  of Expr                                // `= expr`
    | FBBlock of Block

and FunctionDecl =
    { DocComments: DocComment list
      Annotations: Annotation list
      Visibility:  Visibility option
      IsAsync:     bool
      Name:        string
      Generics:    GenericParams option
      Params:      Param list
      Return:      TypeExpr option
      Where:       WhereClause option
      Contracts:   ContractClause list
      Body:        FunctionBody option               // None for sigs/extern
      Span:        Span }

and FunctionSig =
    { IsAsync:    bool
      Name:       string
      Generics:   GenericParams option
      Params:     Param list
      Return:     TypeExpr option
      Where:      WhereClause option
      Contracts:  ContractClause list
      Span:       Span }

and AssociatedTypeDecl =
    { Name:    string
      Default: TypeExpr option
      Span:    Span }

and InterfaceMember =
    | IMSig   of FunctionSig
    | IMFunc  of FunctionDecl                        // default method
    | IMAssoc of AssociatedTypeDecl

and InterfaceDecl =
    { Name:     string
      Generics: GenericParams option
      Where:    WhereClause option
      Members:  InterfaceMember list
      Span:     Span }

and ImplMember =
    | IMplFunc  of FunctionDecl
    | IMplAssoc of AssociatedTypeDecl

and ImplDecl =
    { Generics:  GenericParams option
      Interface: ConstraintRef
      Target:    TypeExpr
      Where:     WhereClause option
      Members:   ImplMember list
      Span:      Span }



// ---------------------------------------------------------------------------
// §7. Wire blocks, user scopes, extern packages.
// ---------------------------------------------------------------------------

and WireMember =
    | WMProvided  of name: string * ty: TypeExpr * Span
    | WMSingleton of name: string * ty: TypeExpr * init: Expr * Span
    | WMScoped    of scope: string * name: string * ty: TypeExpr * init: Expr * Span
    | WMBind      of interface': TypeExpr * provider: Expr * Span
    | WMExpose    of name: string * Span
    | WMLocal     of name: string * ty: TypeExpr option * init: Expr * Span

and WireDecl =
    { Name:    string
      Params:  Param list
      Members: WireMember list
      Span:    Span }

and ScopeKindDecl =
    { Name: string
      Span: Span }

and ExternMember =
    | EMRecord       of RecordDecl
    | EMExposedRec   of ExposedRecordDecl
    | EMUnion        of UnionDecl
    | EMEnum         of EnumDecl
    | EMOpaque       of OpaqueTypeDecl
    | EMSig          of FunctionSig
    | EMTypeAlias    of TypeAliasDecl
    | EMDistinctType of DistinctTypeDecl

and ExternPackageDecl =
    { Path:        ModulePath
      Annotations: Annotation list
      Members:     ExternMember list
      Span:        Span }

/// `extern type Foo = "System.Foo"` declares a Lyric-side type
/// alias for a CLR type loaded in the AppDomain.  User code treats
/// `Foo` as an opaque handle: it can be returned from extern
/// functions, passed to other extern functions, stored in
/// variables — but the bootstrap doesn't yet expose its fields or
/// allow construction outside the FFI boundary.
and ExternTypeDecl =
    { Name:        string
      ClrName:     string
      Span:        Span }


// ---------------------------------------------------------------------------
// §8. Test items (`test`, `property`, `fixture`).
// ---------------------------------------------------------------------------

and TestDecl =
    { Title: string
      Body:  Block
      Span:  Span }

and PropertyBinder =
    { Name: string
      Type: TypeExpr
      Span: Span }

and PropertyDecl =
    { Title:    string
      ForAll:   PropertyBinder list
      Where:    Expr option
      Body:     Block
      Span:     Span }

and FixtureDecl =
    { Name: string
      Type: TypeExpr option
      Init: Expr
      Span: Span }


// ---------------------------------------------------------------------------
// §9. Expressions (full grammar; precedence is encoded in the parser, not
// the AST — the AST stores already-parsed shapes).
// ---------------------------------------------------------------------------

and Expr =
    { Kind: ExprKind
      Span: Span }

and ExprKind =
    /// A literal value.
    | ELiteral of Literal

    /// An interpolated string. Each segment is either literal text or
    /// an interpolated expression.
    | EInterpolated of segments: InterpolatedSegment list

    /// An identifier or qualified path used in expression position.
    | EPath of ModulePath

    /// `(e)` — explicit parenthesisation preserved for span fidelity.
    | EParen of Expr

    /// `(a, b)` — tuple literal.
    | ETuple of Expr list

    /// `[a, b, c]` — list literal.
    | EList of Expr list

    /// `if cond then a else b` (`thenForm = true`) or
    /// `if cond { … } [else { … }]` (`thenForm = false`).
    | EIf of cond: Expr * thenBranch: ExprOrBlock * elseBranch: ExprOrBlock option * thenForm: bool

    /// `match e { case … -> … }`.
    | EMatch of scrutinee: Expr * arms: MatchArm list

    /// `await e`.
    | EAwait of Expr

    /// `spawn e`.
    | ESpawn of Expr

    /// `try e` — expression form (returns Result-shaped).
    | ETry of Expr

    /// `old(e)` — only valid inside ensures clauses.
    | EOld of Expr

    /// `forall (x: T, …) [where φ] {ψ}` or `… implies ψ`.
    | EForall of binders: PropertyBinder list * where: Expr option * body: Expr

    /// `exists (x: T, …) [where φ] {ψ}`.
    | EExists of binders: PropertyBinder list * where: Expr option * body: Expr

    /// `self`.
    | ESelf

    /// `result` — only valid inside ensures clauses.
    | EResult

    /// `{ x: Int, y: Int -> e }` lambda; or a block-style `{ … }`.
    | ELambda of params': LambdaParam list * body: Block

    /// A call: `f(args…)`. `f` is any expression.
    | ECall of fn: Expr * args: CallArg list

    /// `f[A, B]` — explicit type-argument application at call site.
    | ETypeApp of fn: Expr * args: TypeArg list

    /// `a[i, j]` — indexing.
    | EIndex of receiver: Expr * indices: Expr list

    /// `e.field` or `e.method`.
    | EMember of receiver: Expr * name: string

    /// `e?` — error-propagation postfix.
    | EPropagate of Expr

    /// Prefix unary: `-x`, `not x`, `&x`.
    | EPrefix of op: PrefixOp * operand: Expr

    /// Binary: `a + b`, `a == b`, `a or b`, …
    | EBinop of op: BinOp * lhs: Expr * rhs: Expr

    /// Range expression: `a..b`, `a..=b`, `..=b`, `a..`.
    | ERange of RangeBound

    /// Assignment expression (only valid in statement position).
    | EAssign of target: Expr * op: AssignOp * value: Expr

    /// A braced block in expression position. Used to wrap diverging
    /// statements (`return`, `break`, `continue`, `throw`, `try …`)
    /// when they appear as the RHS of an operator like `??` or as a
    /// match-arm body.
    | EBlock of Block

    /// Recovery hatch.
    | EError

and ExprOrBlock =
    | EOBExpr  of Expr
    | EOBBlock of Block

and InterpolatedSegment =
    | ISText of string * Span
    | ISExpr of Expr

and CallArg =
    | CANamed      of name: string * value: Expr * Span
    | CAPositional of Expr

and LambdaParam =
    { Name: string
      Type: TypeExpr option
      Span: Span }

and MatchArm =
    { Pattern: Pattern
      Guard:   Expr option
      Body:    ExprOrBlock
      Span:    Span }

and PrefixOp = PreNeg | PreNot | PreRef

and BinOp =
    | BAdd | BSub | BMul | BDiv | BMod
    | BAnd | BOr  | BXor
    | BEq  | BNeq | BLt  | BLte | BGt | BGte
    | BCoalesce
    | BImplies                                    // contract sub-language

and AssignOp =
    | AssEq | AssPlus | AssMinus | AssStar | AssSlash | AssPercent


// ---------------------------------------------------------------------------
// §10. Statements and blocks.
// ---------------------------------------------------------------------------

and Block =
    { Statements: Statement list
      Span:       Span }

and Statement =
    { Kind: StatementKind
      Span: Span }

and StatementKind =
    /// `val pat: T = expr` / `var x: T = expr` / `let x: T = expr`.
    | SLocal       of LocalBinding
    /// Assignment statement (uses `=`/`+=` etc.).
    | SAssign      of target: Expr * op: AssignOp * value: Expr
    | SReturn      of Expr option
    | SBreak       of label: string option
    | SContinue    of label: string option
    | SThrow       of Expr
    | STry         of body: Block * catches: CatchClause list
    | SDefer       of Block
    | SScope       of binding: string option * body: Block
    | SFor         of label: string option * pat: Pattern * iter: Expr * body: Block
    | SWhile       of label: string option * cond: Expr * body: Block
    | SLoop        of label: string option * body: Block        // `do { … }`
    | SExpr        of Expr
    /// `lhs -> rhs` — stub-builder DSL rule entry inside a `{ … }`
    /// lambda body, e.g. `it.findById(x) -> Some(y)`. Carried as an
    /// opaque pair through the AST; the type checker decides whether
    /// the enclosing context (a stub-builder lambda) admits it.
    | SRule        of lhs: Expr * rhs: Expr
    | SItem        of Item                                    // nested item declaration

and LocalBinding =
    | LBVal of pat: Pattern * ty: TypeExpr option * init: Expr
    | LBVar of name: string * ty: TypeExpr option * init: Expr option
    | LBLet of name: string * ty: TypeExpr option * init: Expr

and CatchClause =
    { Type:   string
      Bind:   string option
      Body:   Block
      Span:   Span }


// ---------------------------------------------------------------------------
// §11. Items (top-level declarations) and source file.
// ---------------------------------------------------------------------------

and Item =
    { DocComments: DocComment list
      Annotations: Annotation list
      Visibility:  Visibility option
      Kind:        ItemKind
      Span:        Span }

and ItemKind =
    | IConst        of ConstDecl
    | IVal          of ValDecl
    | IFunc         of FunctionDecl
    | ITypeAlias    of TypeAliasDecl
    | IDistinctType of DistinctTypeDecl
    | IRecord       of RecordDecl
    | IExposedRec   of ExposedRecordDecl
    | IUnion        of UnionDecl
    | IEnum         of EnumDecl
    | IOpaque       of OpaqueTypeDecl
    | IProtected    of ProtectedTypeDecl
    | IInterface    of InterfaceDecl
    | IImpl         of ImplDecl
    | IWire         of WireDecl
    | IScopeKind    of ScopeKindDecl
    | IExtern       of ExternPackageDecl
    | IExternType   of ExternTypeDecl
    | ITest         of TestDecl
    | IProperty     of PropertyDecl
    | IFixture      of FixtureDecl
    | IError        // recovery placeholder

and ConstDecl =
    { Name: string
      Type: TypeExpr
      Init: Expr
      Span: Span }

and ValDecl =
    { Pattern: Pattern
      Type:    TypeExpr option
      Init:    Expr
      Span:    Span }


// ---------------------------------------------------------------------------
// §12. Imports and source file.
// ---------------------------------------------------------------------------

and ImportItem =
    { Name:  string
      Alias: string option
      Span:  Span }

and ImportSelector =
    /// `import Time.Instant [as Inst]`.
    | ISSingle of ImportItem
    /// `import Money.{Amount, Cents [as C]}`.
    | ISGroup  of ImportItem list

and ImportDecl =
    { Path:     ModulePath
      Selector: ImportSelector option
      Alias:    string option           // `import std.collections as Coll`
      IsPubUse: bool                    // `pub use Money.Amount`
      Span:     Span }

and PackageDecl =
    { Path: ModulePath
      Span: Span }

and SourceFile =
    { ModuleDoc:   DocComment list
      FileLevelAnnotations: Annotation list
      Package:     PackageDecl
      Imports:     ImportDecl list
      Items:       Item list
      Span:        Span }
