//! typechecker_checker.l — public entry point of the type checker.
//! Mirrors compiler/src/Lyric.TypeChecker/Checker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Std.String
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols
import Lyric.Resolve.{DepPackage, buildResolverContext}
import Std.Environment.{getVarOrDefault}
import Lyric.Fmt as Fmt

// ─────────────────────────────────────────────────────────────────────────────
// §1. Check result.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record CheckResult {
  file: SourceFile
  symbols: SymbolTable
  sigs: Map[String, ResolvedSignature]
  diagnostics: List[Diagnostic]
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Duplicate-name detection helpers.
// ─────────────────────────────────────────────────────────────────────────────
func funcArityExists(tbl: in SymbolTable, name: in String, arity: in Int): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported {
      match sym.kind {
        case DKFunc(fd) -> {
          if fd.params.count == arity {
            return true
          }
        }
        case _ -> {
        }
      }
    }
    i = i + 1
  }
  false
}

func hasPriorUserSym(tbl: in SymbolTable, name: in String): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported {
      return true
    }
    i = i + 1
  }
  false
}

// Same case name is only a duplicate when it belongs to the same parent
// union/enum (same parentId).  Cases with the same name in *different* unions
// or enums are distinct and must be allowed — they are distinguished at use
// sites via qualified patterns (`Color.Same` vs `Shape.Same`, #3349).
func caseNameExistsForParent(tbl: in SymbolTable, name: in String, parentId: in SymbolId): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported {
      val sameParent = match sym.kind {
        case DKUnionCase(pid, _) -> symbolIdEq(pid, parentId)
        case DKEnumCase(pid, _) -> symbolIdEq(pid, parentId)
        case _ -> false
      }
      if sameParent {
        return true
      }
    }
    i = i + 1
  }
  false
}

func checkDuplicate(
  tbl: in SymbolTable, diag: in List[Diagnostic], name: in String, kind: in DeclKind, span: in Span
): Unit {
  val isDup = match kind {
    case DKFunc(fd) -> funcArityExists(tbl, name, fd.params.count)
    case DKUnionCase(parentId, _) -> caseNameExistsForParent(tbl, name, parentId)
    case DKEnumCase(parentId, _) -> caseNameExistsForParent(tbl, name, parentId)
    case _ -> hasPriorUserSym(tbl, name)
  }
  if isDup {
    diag.add(errorDiagnostic("T0001", "duplicate name '" + name + "'", span))
  }
}

func t0087Msg(name: in String): String {
  "cannot reassign immutable binding '" + name +
    "' (`val`/`let`/`in` prevents rebinding, not mutation of the referenced object)"
}

// T0087's message for an assignment to the immutable binding `b`.
func t0087BindingMsg(b: in LocalBinding): String {
  if b.capturedByRefParam {
    "cannot assign '" + b.name + "' inside a lambda: it is an `out`/`inout` parameter of the enclosing function, " +
      "and a lambda captures its value, not the caller's place (D183); assign it outside the lambda"
  } else {
    t0087Msg(b.name)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Item registration.
// ─────────────────────────────────────────────────────────────────────────────
func addSym(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  isImported: in Bool,
  originPkg: in String,
  name: in String,
  kind: in DeclKind,
  vis: in Option[Visibility],
  span: in Span,
): Symbol {
  addSymDerived(tbl, diag, isImported, originPkg, name, kind, vis, span, newList())
}

func addSymDerived(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  isImported: in Bool,
  originPkg: in String,
  name: in String,
  kind: in DeclKind,
  vis: in Option[Visibility],
  span: in Span,
  derives: in List[String],
): Symbol {
  if not isImported {
    checkDuplicate(tbl, diag, name, kind, span)
  }
  val sym = Symbol(
    name = name,
    kind = kind,
    declSpan = span,
    visibility = vis,
    isImported = isImported,
    originPackage = originPkg,
    derives = derives
  )
  symTableAdd(tbl, sym)
  sym
}

func extractDerives(anns: in List[Annotation]): List[String] {
  val result: List[String] = newList()
  var i = 0
  while i < anns.count {
    val ann = anns[i]
    if ann.name.segments.count == 1 and ann.name.segments[0] == "derive" {
      var j = 0
      while j < ann.args.count {
        match ann.args[j] {
          case ABare(nm, _) -> result.add(nm)
          case AAName(nm, _, _) -> result.add(nm)
          case ALiteral(_, _) -> {
          }
          case AACall(_, _, _) -> {
          }
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  result
}

// The declared name of one `extern package { ... }` member, whatever kind
// it is (#6361 — feeds `symTableAddExternBlockMember`).
func externMemberDeclName(m: in ExternMember): String {
  match m {
    case EMRecord(decl) -> decl.name
    case EMExposedRec(decl) -> decl.name
    case EMUnion(decl) -> decl.name
    case EMEnum(decl) -> decl.name
    case EMOpaque(decl) -> decl.name
    case EMSig(sig) -> sig.name
    case EMTypeAlias(decl) -> decl.name
    case EMDistinctType(decl) -> decl.name
  }
}

func registerItem(
  tbl: in SymbolTable, diag: in List[Diagnostic], isImported: in Bool, originPkg: in String, it: in Item
): Unit {
  val vis = it.visibility
  val span = it.span
  match it.kind {
    case IRecord(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSymDerived(
        tbl,
        diag,
        isImported,
        originPkg,
        decl.name,
        DKRecord(id = tid, decl = decl),
        vis,
        span,
        extractDerives(it.annotations)
      )
    }
    case IExposedRec(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSymDerived(
        tbl,
        diag,
        isImported,
        originPkg,
        decl.name,
        DKExposedRec(id = tid, decl = decl),
        vis,
        span,
        extractDerives(it.annotations)
      )
    }
    case IUnion(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSymDerived(
        tbl,
        diag,
        isImported,
        originPkg,
        decl.name,
        DKUnion(id = tid, decl = decl),
        vis,
        span,
        extractDerives(it.annotations)
      )
      var i = 0
      while i < decl.cases.count {
        val c = decl.cases[i]
        val _ = addSym(tbl, diag, isImported, originPkg, c.name, DKUnionCase(parentId = tid, uc = c), vis, c.span)
        i = i + 1
      }
    }
    case IEnum(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKEnum(id = tid, decl = decl), vis, span)
      var i = 0
      while i < decl.cases.count {
        val c = decl.cases[i]
        val _ = addSym(tbl, diag, isImported, originPkg, c.name, DKEnumCase(parentId = tid, ec = c), vis, c.span)
        i = i + 1
      }
    }
    case IOpaque(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKOpaque(id = tid, decl = decl), vis, span)
    }
    case IProtected(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKProtected(id = tid, decl = decl), vis, span)
    }
    case IDistinctType(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKDistinctType(id = tid, decl = decl), vis, span)
    }
    case ITypeAlias(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKTypeAlias(decl = decl), vis, span)
    }
    case IInterface(decl) -> {
      val tid = symTableTypeSymbolId(tbl, originPkg, decl.name)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKInterface(id = tid, decl = decl), vis, span)
    }
    case IExternType(decl) -> {
      // An extern type with a host name is identified by it
      // (`externTypeDefPath`), so the *same* extern type (e.g. `extern type
      // List[T] = "System.Collections.Generic.List`1"`, threaded into many
      // packages) is one `SymbolId` wherever it is declared: two ids for one
      // host type made `List[String]` and `newList()`'s `List[T]` different
      // types, a spurious `T0060` that depended on registration order (#2394).
      val tid = if decl.clrName.length > 0 {
        symTableInternDefPath(tbl, externTypeDefPath(decl.clrName))
      } else {
        symTableTypeSymbolId(tbl, originPkg, decl.name)
      }
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKExternType(id = tid, decl = decl), vis, span)
    }
    case IFunc(decl) -> {
      checkReservedBuiltinFuncDecl(diag, isImported, originPkg, decl.name, span)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKFunc(decl = decl), vis, span)
    }
    case IExternFunc(decl) -> {
      checkReservedBuiltinFuncDecl(diag, isImported, originPkg, decl.name, span)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKFunc(decl = externFuncAsFunctionDecl(decl)), vis, span)
    }
    case IConst(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKConst(decl = decl), vis, span)
    }
    case IVal(decl) -> {
      match decl.pattern.kind {
        case PBinding(name, None) -> {
          val _ = addSym(tbl, diag, isImported, originPkg, name, DKVal(decl = decl), vis, span)
        }
        case _ -> {
        }
      }
    }
    case IWire(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKWire(decl = decl), vis, span)
    }
    case IScopeKind(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKScopeKind(decl = decl), vis, span)
    }
    case ITest(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.title, DKTest(decl = decl), vis, span)
    }
    case IProperty(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.title, DKProperty(decl = decl), vis, span)
    }
    // `lyric test` makes a fixture a module-level `val` (`Lyric.TestSynth`);
    // a test body reads it as one in every command (#8308).
    case IFixture(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKVal(decl = fixtureAsVal(decl)), vis, span)
    }
    case IConfig(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKConfig(decl = decl), vis, span)
    }
    case IAspect(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKAspect(decl = decl), vis, span)
    }
    case IExtern(decl) -> {
      // Body-less `extern package <Path> { ... }` members are resolved by
      // codegen directly (never through `sigs`/`tbl.symbols`), but a caller
      // addresses them through the ENCLOSING file's own package path (e.g.
      // `Grpc.Kernel.Net.netOpenChannel(...)`), not `decl.path`. Index each
      // member's name under `originPkg` so a qualified reference to one
      // isn't mistaken for a genuine unknown name (#6361).
      var mi = 0
      while mi < decl.members.count {
        symTableAddExternBlockMember(tbl, originPkg, externMemberDeclName(decl.members[mi].kind))
        mi = mi + 1
      }
      // A function member is a symbol of the block's own path (#7934), the
      // spelling its callers use (`lyric.db.Postgres.connect(...)`).
      val blockPath = modulePathJoin(decl.path.segments)
      symTableAddExternPathPackage(tbl, blockPath)
      var fi = 0
      while fi < decl.members.count {
        match externMemberAsFunctionDecl(decl.members[fi]) {
          case Some(fd) -> {
            symTableAddExternBlockMember(tbl, blockPath, fd.name)
            val sym = Symbol(
              name = fd.name,
              kind = DKFunc(decl = fd),
              declSpan = fd.span,
              visibility = fd.visibility,
              isImported = true,
              originPackage = blockPath,
              derives = newList()
            )
            symTableAdd(tbl, sym)
          }
          case None -> ()
        }
        fi = fi + 1
      }
    }
    case IImpl(_) -> {
    }
    // conformance registered post-resolution; see registerImplsFromItems
    case IError -> {
    }
  }
}

/// The module-level `val` a `fixture` stands for: `fixture n[: T] = e` is
/// `val n[: T] = e`, as `Lyric.TestSynth` rewrites it.
func fixtureAsVal(decl: in FixtureDecl): ValDecl {
  ValDecl(
    pattern = Pattern(kind = PBinding(name = decl.name, inner = None), span = decl.nameSpan),
    ty = decl.ty,
    init = decl.init,
    span = decl.span
  )
}

/// A `test "…" { … }` body is checked as `Lyric.TestSynth` compiles it: the
/// body of a parameterless `Unit` function in the module's scope (#8308).
/// Every command that type-checks the module then reports its errors at
/// their own spans, not only `lyric test` after the rewrite.
func checkTestBody(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  pkgName: in String,
  decl: in TestDecl,
): Unit {
  val noLocals: List[LocalBinding] = newList()
  val fn = FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility = None,
    isAsync = false,
    name = "test \"" + decl.title + "\"",
    generics = None,
    params = newList(),
    ret = Some(value = TypeExpr(kind = TUnit, span = decl.span)),
    whereClause = None,
    contracts = newList(),
    body = Some(value = FBBlock(block = decl.body)),
    span = decl.span
  )
  val sig = resolveFunctionSig(tbl, diag, pkgName, fn)
  checkFunctionBody(tbl, sigs, diag, fn, sig, noLocals, noLocals, false, TyError)
}

// The diagnostics of `pkgDiag` that fall inside a dependency's exported
// surface: its `pub` and `internal` declarations and its impls.  A private
// declaration is checked when its own package is, and a consumer can neither
// name nor call it; the private generic helpers a restored package carries for
// its `pub` generics are the one case a consumer meets, when it specialises
// one, and they are tracked with the rest of that path in #8546.  A
// diagnostic belongs to the item whose span, in the same file, contains it.
func exportedSurfaceDiagnostics(items: in List[Item], pkgDiag: in List[Diagnostic]): List[Diagnostic] {
  val kept: List[Diagnostic] = newList()
  for d in pkgDiag {
    val at = d.span.startPos.offset
    var exported = false
    for item in items {
      if d.span.startPos.fileId == item.span.startPos.fileId and at >= item.span.startPos.offset and at <= item.span.endPos.offset {
        exported = match item.kind {
          case IImpl(_) -> true
          // A carried private generic (`__priv_<Pkg>_<name>`) is written to
          // contract metadata as `internal` so a consumer can specialise it,
          // but it is not the package's surface (#8546).
          case IFunc(fd) -> itemRank(item) > 0 and not fd.name.startsWith("__priv_")
          case _ -> itemRank(item) > 0
        }
      }
    }
    if exported {
      kept.add(d)
    }
  }
  kept
}

// T0211: the first error resolving a dependency's own signatures or impls,
// reported against the importing file's package declaration (the dependency's
// spans belong to another file).
func reportDependencySurfaceError(
  diag: in List[Diagnostic], pkg: in String, pkgDiag: in List[Diagnostic], at: in Span
): Unit {
  var i = 0
  while i < pkgDiag.count {
    match pkgDiag[i].severity {
      case DiagError -> {
        val d = pkgDiag[i]
        diag.add(
          errorDiagnostic(
            "T0211",
            "dependency '" + pkg + "' does not resolve: " + d.code + " " + d.message + " (at its line " +
              toString(d.span.startPos.line) +
              ")",
            at
          )
        )
        return
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Record each `impl Iface for Target` conformance keyed by resolved `SymbolId`,
// so the argument-position interface-subtyping check (#1488) can accept a
// `Target` value where an `Iface` parameter is expected.  Keying on `SymbolId`
// (not simple name) keeps it sound across packages: a same-simple-name
// interface in another package has a distinct id and can't satisfy the check
// (#2303).  Must run with the table fully populated and under the items'
// package scope (so the iface/target names resolve to the same ids the call
// site sees); conformance *checking* (T0098/T0099) stays in
// `checkImplConformance`.
func registerImplsFromItems(
  tbl: in SymbolTable, ctx: in GenericContext, diag: in List[Diagnostic], items: in List[Item]
): Unit {
  var i = 0
  while i < items.count {
    symTableEnterSpanFile(tbl, items[i].span)
    match items[i].kind {
      case IImpl(decl) -> {
        val ifaceTy = resolveType(tbl, ctx, diag, mkTypeRef(decl.iface.head, decl.span))
        val targetTy = resolveType(tbl, declGenericContext(decl.generics), diag, decl.target)
        match typeIdOfType(ifaceTy) {
          case Some(ifaceId) -> match typeIdOfType(targetTy) {
            case Some(targetId) -> symTableAddImpl(tbl, targetId, ifaceId)
            case None -> {
            }
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  symTableEnterFile(tbl, -1)
}

// Wrap a `ModulePath` as a `TypeExpr` reference so `resolveType` can resolve an
// interface head (a `ConstraintRef`) the same way it resolves a type position.
func mkTypeRef(path: in ModulePath, span: in Span): TypeExpr {
  TypeExpr(kind = TRef(path = path), span = span)
}

// The `SymbolId` of a resolved user type, or `None` for non-`TyUser` types.
func typeIdOfType(t: in Type): Option[SymbolId] {
  match unrefine(t) {
    case TyUser(id, _, _) -> Some(value = id)
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Range subtype validation (T2.5).
// ─────────────────────────────────────────────────────────────────────────────
// `Short`/`UShort`/`UByte` are DELIBERATELY excluded (#6661 residual,
// D-progress-840): none of the three has a real `PrimType` case
// (`typechecker_types.l`'s `PrimType` union has no `PtShort`/`PtUShort`/
// `PtUByte` variant) or appears in docs/01-language-reference.md §2.1's
// 13-primitive table — they are not Lyric surface types at all (see also
// docs/10-bootstrap-progress.md D-progress-571: "`Short` is not a surface
// Lyric type"). Before this fix, this name-based T0091 gate wrongly
// admitted them: `type Age = UShort range 0 ..= 100` type-checked cleanly
// (no T0091 — the ONLY validation `IDistinctType`'s underlying `TypeExpr`
// ever receives; distinct-type underlyings are never independently
// resolved via `resolveTypePath`), then reached JVM codegen, where
// `Jvm.Codegen.typeExprToJvm` has no `UShort` arm either and erased it to
// "user type in the same package" (`JRef(pkgName + "/UShort")`) — a
// non-numeric `JvmType` that `Jvm.Lowering.jvmVerifierTypeOfUnderlying`'s
// defense-in-depth `case _ -> panic(...)` then hit while building the
// ranged `from`/`tryFrom`'s StackMapTable, crashing the compiler on
// source the checker had just accepted as valid. Rejecting all three here
// makes `type X = UShort/UByte/Short range …` a clean T0091 diagnostic
// instead of ever reaching a backend panic.
func isNumericPrimitiveName(name: in String): Bool {
  name == "Int" or name == "Long" or name == "Byte" or name == "UInt" or name == "ULong" or name == "Float" or
    name == "Double" or
    // `Nat` is a full numeric primitive (`PtNat`, `typechecker_types.l`) and
    // docs/02's worked examples declare `Nat range A..=B` distinct types
    // (e.g. `dbPoolSize: Nat range 1 ..= 100`) — this name-based gate simply
    // never listed it, rejecting every `Nat`-backed range subtype with T0091
    // regardless of the underlying type actually being numeric.
    name == "Nat"
}

func describeFoldError(fe: in FoldError): String {
  match fe {
    case FENotConstant -> "expression is not a compile-time integer constant"
    case FECycle(name) -> "constant '" + name + "' references itself transitively"
    case FEOverflow -> "integer overflow during constant evaluation"
    case FEDivByZero -> "division by zero in constant expression"
    case FEUnsignedNegation(tn, _) -> "it negates a constant of the unsigned type " + tn
  }
}

func foldOrErr(tbl: in SymbolTable, diag: in List[Diagnostic], name: in String, e: in Expr): Option[Long] {
  match tryFoldInt(tbl, e) {
    case FoldOk(v) -> Some(value = v)
    case FoldErr(fe) -> {
      // A negation written in the bound itself is T0147 where it is; one
      // reached through a constant's initialiser was reported at that
      // initialiser, so there the bound just cannot be folded.
      val ownNegation = match fe {
        case FEUnsignedNegation(tn, negSpan) -> if spanWithin(negSpan, e.span) {
          diag.add(errorDiagnostic("T0147", unsignedNegationMessage(tn), negSpan))
          true
        } else {
          false
        }
        case _ -> false
      }
      if not ownNegation {
        diag.add(
          errorDiagnostic(
            "T0093",
            "range subtype '" + name + "' has a symbolic bound that cannot be folded: " + describeFoldError(fe),
            e.span
          )
        )
      }
      None
    }
  }
}

func checkClosed(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  name: in String,
  lo: in Expr,
  hi: in Expr,
  inclusive: in Bool,
  sym: in String,
  span: in Span,
  isULong: in Bool,
): Unit {
  match foldOrErr(tbl, diag, name, lo) {
    case None -> {
    }
    case Some(loV) -> match foldOrErr(tbl, diag, name, hi) {
      case None -> {
      }
      case Some(hiV) -> {
        // A `ULong` bound above Long.MaxValue is a negative pattern
        // (#7839), so the bounds order unsigned.
        val invalid = if isULong {
          if inclusive {
            ulongLessThan(hiV, loV)
          } else {
            not ulongLessThan(loV, hiV)
          }
        } else {
          if inclusive {
            loV > hiV
          } else {
            loV >= hiV
          }
        }
        if invalid {
          val loS = if isULong { ulongPatternToString(loV) } else { toString(loV) }
          val hiS = if isULong { ulongPatternToString(hiV) } else { toString(hiV) }
          diag.add(
            errorDiagnostic("T0090", "range subtype '" + name + "' has empty bounds: " + loS + " " + sym + " " + hiS, span)
          )
        }
      }
    }
  }
}

// #6661: `tryFoldInt`/`foldOrErr`/`checkClosed` above are INTEGER-only (mirror
// `compiler/src/Lyric.TypeChecker/ConstFold.fs`, which the F# emitter never
// needed to extend since range subtypes were an MSIL-only feature there
// too). A `Float`/`Double`-backed range subtype's bounds are float literals
// (`type Weight = Float range 0.0 ..= 100.0`), which `tryFoldInt` rejects
// outright (T0093 "not a compile-time integer constant") — so NO
// `Float`/`Double`-backed NAMED range subtype could be declared at all, on
// EITHER backend, independent of `Jvm.Lowering.emitJvmDistinctBoundsToFail`'s
// bytecode-level `Float` fix (06_items.l/lowering.l) ever running. This
// mirrors `Jvm.Codegen.foldRangeBoundJvm`/`Msil.Codegen.foldRangeBound`'s
// existing literal+negation-only scope (no module-level float `val` lookup)
// — deliberately narrow, since a distinct type's range bounds are meant to
// be simple literal constants.
func tryFoldFloat(e: in Expr): Option[Double] {
  match e.kind {
    case EParen(inner) -> tryFoldFloat(inner)
    case ELiteral(lit) -> match lit {
      case LFloat(v, _, _) -> Some(value = v)
      case LInt(v, _, _) -> Some(value = v.toDouble())
      case _ -> None
    }
    case EPrefix(op, inner) -> match op {
      case PreNeg -> match tryFoldFloat(inner) {
        case Some(v) -> Some(value = 0.0 - v)
        case None -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

func foldOrErrFloat(diag: in List[Diagnostic], name: in String, e: in Expr): Option[Double] {
  match tryFoldFloat(e) {
    case Some(v) -> Some(value = v)
    case None -> {
      diag.add(
        errorDiagnostic(
          "T0093",
          "range subtype '" + name +
            "' has a symbolic bound that cannot be folded: expression is not a compile-time numeric constant",
          e.span
        )
      )
      None
    }
  }
}

func checkClosedFloat(
  diag: in List[Diagnostic],
  name: in String,
  lo: in Expr,
  hi: in Expr,
  inclusive: in Bool,
  sym: in String,
  span: in Span,
): Unit {
  match foldOrErrFloat(diag, name, lo) {
    case None -> {
    }
    case Some(loV) -> match foldOrErrFloat(diag, name, hi) {
      case None -> {
      }
      case Some(hiV) -> {
        val invalid = if inclusive { loV > hiV } else { loV >= hiV }
        if invalid {
          diag.add(
            errorDiagnostic(
              "T0090",
              "range subtype '" + name + "' has empty bounds: " + toString(loV) + " " + sym + " " + toString(hiV),
              span
            )
          )
        }
      }
    }
  }
}

func checkDistinctType(tbl: in SymbolTable, diag: in List[Diagnostic], dt: in DistinctTypeDecl): Unit {
  match dt.rangeClause {
    case None -> {
    }
    case Some(_) -> {
      var isFloatBase = false
      var isULongBase = false
      match dt.underlying.kind {
        case TRef(path) -> {
          if path.segments.count == 1 {
            val uname = path.segments[0]
            if not isNumericPrimitiveName(uname) {
              diag.add(
                errorDiagnostic(
                  "T0091",
                  "range subtype '" + dt.name + "' requires a numeric underlying type, got '" + uname + "'",
                  dt.span
                )
              )
            }
            isFloatBase = uname == "Float" or uname == "Double"
            isULongBase = uname == "ULong"
            match dt.rangeClause {
              case Some(rbFit) -> if isNumericPrimitiveName(uname) {
                checkRangeBoundsFitBase(tbl, diag, "range subtype '" + dt.name + "'", uname, rbFit)
              }
              case None -> ()
            }
          }
        }
        case _ -> {
        }
      }
      match dt.rangeClause {
        case None -> {
        }
        case Some(rb) -> match rb {
          case RBClosed(lo, hi) -> {
            if isFloatBase {
              checkClosedFloat(diag, dt.name, lo, hi, true, "..=", dt.span)
            } else {
              checkClosed(tbl, diag, dt.name, lo, hi, true, "..=", dt.span, isULongBase)
            }
          }
          case RBHalfOpen(lo, hi, bareDotDot) -> {
            val opStr = if bareDotDot { ".." } else { "..<" }
            if isFloatBase {
              checkClosedFloat(diag, dt.name, lo, hi, false, opStr, dt.span)
            } else {
              checkClosed(tbl, diag, dt.name, lo, hi, false, opStr, dt.span, isULongBase)
            }
          }
          case _ -> {
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Where-clause validation (T3 pre-step).
// ─────────────────────────────────────────────────────────────────────────────
func isKnownDeriveMarker(name: in String): Bool {
  name == "Add" or name == "Sub" or name == "Mul" or name == "Div" or name == "Mod" or name == "Compare" or
    name == "Hash" or
    name == "Equals" or
    name == "Default"
}

func isInterfaceSym(tbl: in SymbolTable, name: in String): Bool {
  match constraintInterfaceSym(tbl, name) {
    case None -> false
    case Some(_) -> true
  }
}

func genericNamesContains(names: in List[String], name: in String): Bool {
  var i = 0
  while i < names.count {
    if names[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

func checkWhereClause(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  genericNames: in List[String],
  wc: in Option[WhereClause],
): Unit {
  match wc {
    case None -> {
    }
    case Some(clause) -> {
      var i = 0
      while i < clause.bounds.count {
        val bound = clause.bounds[i]
        if not genericNamesContains(genericNames, bound.name) {
          diag.add(
            errorDiagnostic("T0050", "'where' clause references unknown type parameter '" + bound.name + "'", bound.span)
          )
        }
        var j = 0
        while j < bound.constraints.count {
          val cr = bound.constraints[j]
          val cname = modulePathJoin(cr.head.segments)
          val known = if cr.head.segments.count == 1 { isKnownDeriveMarker(cname) or isPlainMarker(cname) } else { false }
          if not known and not isInterfaceSym(tbl, cname) {
            diag.add(
              errorDiagnostic(
                "T0051",
                "unknown constraint '" + cname + "' in 'where' clause" + symTableHiddenImportHint(tbl, cname),
                cr.span
              )
            )
          }
          j = j + 1
        }
        i = i + 1
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Function signature resolution (T3).
// ─────────────────────────────────────────────────────────────────────────────
func extractGenericNames(gps: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gps {
    case None -> {
    }
    case Some(g) -> {
      var i = 0
      while i < g.params.count {
        match g.params[i] {
          case GPType(name, _) -> names.add(name)
          case GPValue(name, _, _) -> names.add(name)
        }
        i = i + 1
      }
    }
  }
  names
}

// Each constraint is recorded package-qualified when it names an interface
// (resolved here, in the declaring package's scope), so a caller checks it
// against the same interface whatever the caller imports.
func resolveBounds(tbl: in SymbolTable, wc: in Option[WhereClause]): List[ResolvedBound] {
  val result: List[ResolvedBound] = newList()
  match wc {
    case None -> {
    }
    case Some(clause) -> {
      var i = 0
      while i < clause.bounds.count {
        val b = clause.bounds[i]
        val constraints: List[String] = newList()
        var j = 0
        while j < b.constraints.count {
          val cr = b.constraints[j]
          val written = modulePathJoin(cr.head.segments)
          match constraintInterfaceSym(tbl, written) {
            case Some(iface) -> if iface.originPackage.length > 0 {
              constraints.add(iface.originPackage + "." + iface.name)
            } else {
              constraints.add(written)
            }
            case None -> constraints.add(written)
          }
          j = j + 1
        }
        result.add(ResolvedBound(name = b.name, constraints = constraints))
        i = i + 1
      }
    }
  }
  result
}

// Return true if any annotation on the function has the single-segment name `name`.
func annotationsHaveName(anns: in List[Annotation], name: in String): Bool {
  for ann in anns {
    if ann.name.segments.count == 1 and ann.name.segments[0] == name {
      return true
    }
  }
  false
}

func fnHasAnnotation(fn: in FunctionDecl, name: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val ann = fn.annotations[i]
    if ann.name.segments.count == 1 and ann.name.segments[0] == name {
      return true
    }
    i = i + 1
  }
  false
}

/// What `exprContains` looks for: a generator `yield` (not inside a nested
/// lambda), or a `forall`/`exists` quantifier (anywhere, as the contract
/// elaborator's `exprHasQuantifier` finds it).
union ExprProbe {
  case ProbeYield
  case ProbeQuantifier
}

// Return true if any expression in the block/statement/expr tree is what
// `probe` names; a `yield` inside a nested ELambda body does not count.
// Mirror of AsyncStateMachine.bodyContainsYield; kept here because
// Lyric.TypeChecker cannot depend on Lyric.Emitter.  Keep both in sync.
func exprContains(e: in Expr, probe: in ExprProbe): Bool {
  match e.kind {
    case EYield(inner) -> match probe { case ProbeYield -> true; case ProbeQuantifier -> exprContains(inner, probe) }
    // yield inside a lambda is not a generator yield
    case ELambda(_, body) -> match probe {
      case ProbeYield -> false
      case ProbeQuantifier -> blockContains(body, probe)
    }
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EResult -> false
    case EError -> false
    case EParen(inner) -> exprContains(inner, probe)
    case EAwait(inner) -> exprContains(inner, probe)
    case ESpawn(inner) -> exprContains(inner, probe)
    case EOld(inner) -> exprContains(inner, probe)
    case EPropagate(inner) -> exprContains(inner, probe)
    case ETry(inner) -> exprContains(inner, probe)
    case EPrefix(_, inner) -> exprContains(inner, probe)
    case ETuple(elems) -> listAnyExprContains(elems, probe)
    case EList(elems) -> listAnyExprContains(elems, probe)
    case EInterpolated(segs) -> {
      var found = false
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> {
            if exprContains(se, probe) {
              found = true
            }
          }
          case ISText(_) -> {
          }
        }
        i = i + 1
      }
      found
    }
    case EBinop(_, l, r) -> exprContains(l, probe) or exprContains(r, probe)
    case EAssign(t, _, v) -> exprContains(t, probe) or exprContains(v, probe)
    case EMember(recv, _) -> exprContains(recv, probe)
    case ETypeApp(f, _) -> exprContains(f, probe)
    case EIndex(recv, idxs) -> exprContains(recv, probe) or listAnyExprContains(idxs, probe)
    case ECall(f, args) -> {
      if exprContains(f, probe) {
        return true
      }
      var i = 0
      while i < args.count {
        val found = match args[i] {
          case CAPositional(v) -> exprContains(v, probe)
          case CANamed(_, v, _) -> exprContains(v, probe)
        }
        if found {
          return true
        }
        i = i + 1
      }
      false
    }
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> exprContains(a, probe) or exprContains(b, probe)
      case RBHalfOpen(a, b, _) -> exprContains(a, probe) or exprContains(b, probe)
      case RBLowerOpen(a) -> exprContains(a, probe)
      case RBUpperOpen(a) -> exprContains(a, probe)
    }
    case EIf(c, t, eOpt, _) -> {
      if exprContains(c, probe) {
        return true
      }
      val inT = match t { case EOBExpr(te) -> exprContains(te, probe); case EOBBlock(tb) -> blockContains(tb, probe) }
      if inT {
        return true
      }
      match eOpt {
        case None -> false
        case Some(b) -> match b {
          case EOBExpr(ee) -> exprContains(ee, probe)
          case EOBBlock(eb) -> blockContains(eb, probe)
        }
      }
    }
    case EMatch(subj, arms) -> {
      if exprContains(subj, probe) {
        return true
      }
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val inGuard = match arm.guard { case None -> false; case Some(g) -> exprContains(g, probe) }
        if inGuard {
          return true
        }
        val inBody = match arm.body {
          case EOBExpr(ae) -> exprContains(ae, probe)
          case EOBBlock(ab) -> blockContains(ab, probe)
        }
        if inBody {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> blockContains(blk, probe)
    case EUnsafe(blk) -> blockContains(blk, probe)
    case EForall(_, w, body, _) -> {
      if isQuantifierProbe(probe) {
        return true
      }
      val inW = match w { case None -> false; case Some(we) -> exprContains(we, probe) }
      inW or exprContains(body, probe)
    }
    case EExists(_, w, body, _) -> {
      if isQuantifierProbe(probe) {
        return true
      }
      val inW = match w { case None -> false; case Some(we) -> exprContains(we, probe) }
      inW or exprContains(body, probe)
    }
  }
}

func listAnyExprContains(es: in List[Expr], probe: in ExprProbe): Bool {
  var i = 0
  while i < es.count {
    if exprContains(es[i], probe) {
      return true
    }
    i = i + 1
  }
  false
}

func blockContains(blk: in Block, probe: in ExprProbe): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContains(blk.statements[i], probe) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContains(stmt: in Statement, probe: in ExprProbe): Bool {
  match stmt.kind {
    case SExpr(e) -> exprContains(e, probe)
    case SThrow(e) -> exprContains(e, probe)
    case SReturn(Some(e)) -> exprContains(e, probe)
    case SReturn(None) -> false
    case SBreak(_) -> false
    case SContinue(_) -> false
    case SInvariant(_) -> false
    case SItem(_) -> false
    case SAssign(t, _, v) -> exprContains(t, probe) or exprContains(v, probe)
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> exprContains(e, probe)
      case LBLet(_, _, e) -> exprContains(e, probe)
      case LBVar(_, _, Some(e)) -> exprContains(e, probe)
      case LBVar(_, _, None) -> false
    }
    case STry(body, catches, finally_) -> {
      if blockContains(body, probe) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockContains(catches[i].body, probe) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContains(fb, probe)
      }
    }
    case SDefer(b) -> blockContains(b, probe)
    case SScope(_, b) -> blockContains(b, probe)
    case SLoop(_, b) -> blockContains(b, probe)
    case SFor(_, _, iter, body) -> exprContains(iter, probe) or blockContains(body, probe)
    case SWhile(_, cond, body) -> exprContains(cond, probe) or blockContains(body, probe)
    case SRule(l, r) -> exprContains(l, probe) or exprContains(r, probe)
  }
}

func isQuantifierProbe(probe: in ExprProbe): Bool {
  match probe {
    case ProbeQuantifier -> true
    case ProbeYield -> false
  }
}

func exprContainsYield(e: in Expr): Bool {
  exprContains(e, ProbeYield)
}

func blockContainsYield(blk: in Block): Bool {
  blockContains(blk, ProbeYield)
}

/// True when `e` holds a `forall`/`exists` anywhere.
func exprHasQuantifier(e: in Expr): Bool {
  exprContains(e, ProbeQuantifier)
}

func funcBodyContainsYield(fn: in FunctionDecl): Bool {
  match fn.body {
    case None -> false
    case Some(body) -> match body { case FBExpr(e) -> exprContainsYield(e); case FBBlock(b) -> blockContainsYield(b) }
  }
}

func resolveFunctionSig(
  tbl: in SymbolTable, diag: in List[Diagnostic], pkgName: in String, fn: in FunctionDecl
): ResolvedSignature {
  val genericNames = extractGenericNames(fn.generics)
  val ctx = newGenericContext()
  if genericNames.count > 0 {
    gctxPush(ctx, genericNames)
  }

  checkWhereClause(tbl, diag, genericNames, fn.whereClause)

  val bounds = resolveBounds(tbl, fn.whereClause)

  val params: List[ResolvedParam] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    val resolvedTy = resolveType(tbl, ctx, diag, p.ty)
    params.add(
      ResolvedParam(
        name = p.name,
        ty = resolvedTy,
        mode = p.mode,
        hasDefault = match p.dflt { case None -> false; case Some(d) -> not isUnexportedDefaultCall(d) },
        span = p.span,
        tyExpr = Some(value = p.ty),
        defaultInert = match p.dflt { case None -> false; case Some(d) -> exprIsInert(d) },
        defaultUnavailable = match p.dflt { case None -> false; case Some(d) -> isUnexportedDefaultCall(d) }
      )
    )
    i = i + 1
  }

  val returnTy = match fn.ret { case None -> TyPrim(pt = PtUnit); case Some(te) -> resolveType(tbl, ctx, diag, te) }

  val isHot = fnHasAnnotation(fn, "hot")
  val isGen = funcBodyContainsYield(fn)

  if isGen and not fn.isAsync {
    diag.add(errorDiagnostic("T0094", "yield is only valid inside an async function", fn.span))
  }
  if isHot and fn.isAsync and isGen {
    diag.add(
      warningDiagnostic(
        "T0096",
        "@hot on an async generator has no effect: the synthesised generator class uses AsyncTaskMethodBuilder, not AsyncValueTaskMethodBuilder; @hot is ignored",
        fn.span
      )
    )
  }

  ResolvedSignature(
    generics = genericNames,
    bounds = bounds,
    params = params,
    returnTy = returnTy,
    isAsync = fn.isAsync,
    isHot = isHot,
    isGenerator = fn.isAsync and isGen,
    originPackage = pkgName,
    span = fn.span,
    isPure = fnHasAnnotation(fn, "pure"),
    isIo = fnHasAnnotation(fn, "io"),
    isEntry = false,
    isExternFunc = false
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Build signatures map for a list of items.
// ─────────────────────────────────────────────────────────────────────────────
// Register `sg` as an overload candidate for `arityKey`, placing it in the next
// free indexed slot (`arityKey@0`, `arityKey@1`, …).  Probing for the first
// absent index means candidate registration auto-continues across the
// imported-then-user `addSigsFromItems` passes that share one `sigs` map, so a
// user overload is appended after the imported ones rather than colliding.
pub func registerOverloadCandidate(
  sigs: in Map[String, ResolvedSignature],
  arityKey: in String,
  sg: in ResolvedSignature,
): Unit {
  var i = 0
  var placed = false
  while not placed {
    val k = arityKey + "@" + toString(i)
    if not sigs.containsKey(k) {
      sigs.add(k, sg)
      placed = true
    } else {
      i = i + 1
    }
  }
}

// The `sigs` slot prefix under which every function named `name` is
// registered (see `addSigsFromItems`).  It holds no `/`, so it never reads as
// an arity key.
pub func byNameSigKey(name: in String): String {
  "~fn~" + name
}

// Gather every overload candidate registered for `arityKey` (the indexed
// `arityKey@0…` slots written by `registerOverloadCandidate`), stopping at the
// first gap.  Returns the candidates in registration order.
pub func gatherOverloadCandidates(sigs: in Map[String, ResolvedSignature], arityKey: in String): List[ResolvedSignature] {
  val acc: List[ResolvedSignature] = newList()
  var i = 0
  var more = true
  while more {
    match mapGet(sigs, arityKey + "@" + toString(i)) {
      case Some(s) -> {
        acc.add(s)
        i = i + 1
      }
      case None -> {
        more = false
      }
    }
  }
  acc
}

// An `extern func` (D-N-007) type-checks at call sites exactly like a
// body-less Lyric function with the declared signature: the symbol table and
// the `sigs` map both see it through this view.  The native backend resolves
// the C symbol; the managed backends reject the item, and the
// `_kernel_native/` packages that declare them load for `--target native` only.
pub func externFuncAsFunctionDecl(decl: in ExternFuncDecl): FunctionDecl {
  val emptyDocs: List[DocComment] = newList()
  val emptyAnns: List[Annotation] = newList()
  val emptyContracts: List[ContractClause] = newList()
  FunctionDecl(
    docComments = emptyDocs,
    annotations = emptyAnns,
    visibility = None,
    isAsync = false,
    name = decl.name,
    generics = None,
    params = decl.params,
    ret = decl.ret,
    whereClause = None,
    contracts = emptyContracts,
    body = None,
    span = decl.span
  )
}

// The function a body-less `extern package { ... }` member declares, as the
// body-less function the checker already types calls against (#7934); `None`
// for a type member.
func externMemberAsFunctionDecl(m: in ExternMemberDecl): Option[FunctionDecl] {
  match m.kind {
    case EMSig(sig) -> Some(
      value = FunctionDecl(
        docComments = m.docComments,
        annotations = m.annotations,
        visibility = m.visibility,
        isAsync = sig.isAsync,
        name = sig.name,
        generics = sig.generics,
        params = sig.params,
        ret = sig.ret,
        whereClause = sig.whereClause,
        contracts = sig.contracts,
        body = None,
        span = sig.span
      )
    )
    case _ -> None
  }
}

func withOriginPackage(sg: in ResolvedSignature, originPkg: in String): ResolvedSignature {
  ResolvedSignature(
    generics = sg.generics,
    bounds = sg.bounds,
    params = sg.params,
    returnTy = sg.returnTy,
    isAsync = sg.isAsync,
    isHot = sg.isHot,
    isGenerator = sg.isGenerator,
    originPackage = originPkg,
    span = sg.span,
    isPure = sg.isPure,
    isIo = sg.isIo,
    isEntry = sg.isEntry,
    isExternFunc = sg.isExternFunc
  )
}

func asExternFuncSig(sg: in ResolvedSignature): ResolvedSignature {
  ResolvedSignature(
    generics = sg.generics,
    bounds = sg.bounds,
    params = sg.params,
    returnTy = sg.returnTy,
    isAsync = sg.isAsync,
    isHot = sg.isHot,
    isGenerator = sg.isGenerator,
    originPackage = sg.originPackage,
    span = sg.span,
    isPure = sg.isPure,
    isIo = sg.isIo,
    isEntry = sg.isEntry,
    isExternFunc = true
  )
}

func itemsDeclareFunc(items: in List[Item], name: in String, arity: in Int): Bool {
  for it in items {
    match it.kind {
      case IFunc(d) -> if d.name == name and d.params.count == arity { return true }
      case IExternFunc(d) -> if d.name == name and d.params.count == arity { return true }
      case _ -> ()
    }
  }
  false
}

func addSigsFromItems(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sigs: in Map[String, ResolvedSignature],
  items: in List[Item],
  isImported: in Bool,
  pkgName: in String,
): Unit {
  var i = 0
  while i < items.count {
    symTableEnterSpanFile(tbl, items[i].span)
    match items[i].kind {
      case IFunc(decl) -> addFuncSig(tbl, diag, sigs, decl, false, isImported, pkgName)
      case IExternFunc(decl) -> addFuncSig(tbl, diag, sigs, externFuncAsFunctionDecl(decl), true, isImported, pkgName)
      case IExtern(decl) -> {
        // Resolved in the enclosing package's scope (its imports name the
        // types), registered under the block's own path (#7934).
        val blockPath = modulePathJoin(decl.path.segments)
        var mi = 0
        while mi < decl.members.count {
          match externMemberAsFunctionDecl(decl.members[mi]) {
            case Some(fd) -> {
              addFuncSigOrigin(tbl, diag, sigs, fd, false, true, pkgName, blockPath)
              // Also addressable through the enclosing package, unless that
              // package declares a function of the name and arity itself.
              if blockPath != pkgName and not itemsDeclareFunc(items, fd.name, fd.params.count) {
                addFuncSigOrigin(tbl, diag, sigs, fd, false, true, pkgName, pkgName)
              }
            }
            case None -> ()
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  symTableEnterFile(tbl, -1)
}

func addFuncSig(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sigs: in Map[String, ResolvedSignature],
  decl: in FunctionDecl,
  isExternFunc: in Bool,
  isImported: in Bool,
  pkgName: in String,
): Unit {
  addFuncSigOrigin(tbl, diag, sigs, decl, isExternFunc, isImported, pkgName, pkgName)
}

// `addFuncSig` for a function whose types resolve in `pkgName`'s scope but
// which is addressed under `originPkg`: an `extern package` member (#7934).
func addFuncSigOrigin(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sigs: in Map[String, ResolvedSignature],
  decl: in FunctionDecl,
  isExternFunc: in Bool,
  isImported: in Bool,
  pkgName: in String,
  originPkg: in String,
): Unit {
  // Imported stdlib functions don't get to shadow the codegen builtins.
  // `println`, `toString`, `panic`, `assert`, `expect`, `default`,
  // `format1`-`format4` are wired in `codegenBuiltinType` with
  // intentionally polymorphic `TyError` parameter types so that
  // ergonomic forms like `println(11)` typecheck.  The stdlib's
  // concrete `pub func println(s: in String): Unit` would, once it's
  // in the `sigs` map, win the `findDirectSig` lookup and reject the
  // Int argument with T0043.  Skipping these names for imports
  // preserves the historical advisory semantics; user code that
  // explicitly defines its own `println` still wins via the user
  // pass that follows.
  if isImported and isCodegenBuiltinName(decl.name) {
    return
  }
  val sg00 = resolveFunctionSig(tbl, diag, pkgName, decl)
  val sg0 = if originPkg == pkgName { sg00 } else { withOriginPackage(sg00, originPkg) }
  val sg = if isExternFunc { asExternFuncSig(sg0) } else { sg0 }
  val name = canonicalDotNamedName(tbl, diag, decl, isImported, pkgName)
  val arityKey = name + "/" + toString(decl.params.count)
  // Sig-map insertion policy.  Imported items use first-in-wins
  // because bare-name collisions across stdlib files (e.g.
  // `toString`, `tryGet` defined in multiple modules) would
  // otherwise crash via `Dictionary.Add`'s duplicate-key throw.
  // User items run after imports and unconditionally overwrite —
  // a user-defined `pub func foo` in the same file MUST win over
  // any imported `foo` so the user's intent shadows the dep,
  // matching the standard import-shadowing semantics every other
  // language's typechecker gives.  Once #1378's stdlib-IFunc
  // collection follow-up lands, this lets user code safely
  // redefine names that happen to overlap with the stdlib
  // (#1383).
  if isImported {
    if not sigs.containsKey(name) {
      sigs.add(name, sg)
    }
    if not sigs.containsKey(arityKey) {
      sigs.add(arityKey, sg)
    }
  } else {
    if sigs.containsKey(name) {
      sigs.remove(name)
    }
    sigs.add(name, sg)
    if sigs.containsKey(arityKey) {
      sigs.remove(arityKey)
    }
    sigs.add(arityKey, sg)
  }
  // Overload candidates (#1488 category C): same-name/same-arity functions
  // that differ only in parameter types (e.g. `Std.Char.toUpper(Char)` vs
  // `Std.String.toUpper(String)`) collide on `arityKey` under first-in-
  // wins, so a `toUpper("s")` call could be checked against the `Char`
  // overload and wrongly rejected (T0043).  Register every non-generic sig
  // under an indexed `arityKey@i` key so the call site can gather the full
  // candidate set and pick the overload whose params match the argument
  // types via `typeEquiv` (which honours `TyError`/`TyVar` wildcards, so an
  // empty-literal `slice[<error>]` arg still selects the `slice[String]`
  // overload).  Indexing auto-continues across the imported-then-user
  // registration passes (we probe for the next free slot).  Generic sigs
  // are skipped: their `TyVar` params match any argument under `typeEquiv`
  // and would shadow a concrete overload — they keep the arity-key path.
  if sg.generics.count == 0 {
    registerOverloadCandidate(sigs, arityKey, sg)
  }
  // Every function of this name, generic or not, whichever package
  // declares it: the `name` and `arityKey` slots keep only one, which
  // the file's import rule may hide (docs/01 §9.2), so a bare
  // reference picks its visible declaration from here
  // (`visibleBareFuncSigs`).
  registerOverloadCandidate(sigs, byNameSigKey(name), sg)
}

// The name a dot-named function `X.m` is registered and compiled under: when
// `X` is a type alias, the aliased type's (`Int.m` for `alias Num = Int`,
// through chains and imported aliases alike, #8217), recorded in
// `SymbolTable.dotNameRenames`; `decl.name` otherwise.  An alias of a type
// a dot-named function cannot be declared for (a generic instance such as
// `List[Int]`, a function or tuple type) is T0171.
func canonicalDotNamedName(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  decl: in FunctionDecl,
  isImported: in Bool,
  pkgName: in String,
): String {
  val dot = lastIndexOfRaw(decl.name, ".")
  if dot <= 0 {
    return decl.name
  }
  val owner = decl.name.substring(0, dot)
  if not dotOwnerIsAlias(tbl, owner) {
    return decl.name
  }
  val segs: List[String] = newList()
  segs.add(owner)
  val scratch: List[Diagnostic] = newList()
  val t = resolveType(
    tbl,
    newGenericContext(),
    scratch,
    TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = decl.span)), span = decl.span)
  )
  val canonical = match unrefine(t) {
    case TyUser(_, n, targs) -> if targs.count == 0 { n } else { "" }
    case TyPrim(pt) -> primName(pt)
    case TyError -> return decl.name
    case _ -> ""
  }
  if canonical.length == 0 {
    if not isImported {
      val member = decl.name.substring(dot + 1)
      // A generic instance's function is declared for the generic type, with
      // the instance as the receiver's type.
      val instead = match unrefine(t) {
        case TyUser(_, n, _) -> "; declare it for '" + n +
          "' with the instance as the receiver's type: 'func " +
          n +
          "." +
          member +
          "(self: in " +
          renderType(t) +
          ", ...)'"
        case _ -> "; use a plain function taking a '" + renderType(t) + "' instead"
      }
      diag.add(
        errorDiagnostic(
          "T0171",
          "'" + decl.name + "' is declared through the alias '" + owner + "' of '" + renderType(t) +
            "', which is not a plain named type" +
            instead,
          decl.span
        )
      )
    }
    return decl.name
  }
  if canonical == owner {
    return decl.name
  }
  val renamed = canonical + decl.name.substring(dot)
  val key = pkgName + "|" + decl.name
  if not tbl.dotNameRenames.containsKey(key) {
    tbl.dotNameRenames.add(key, renamed)
  }
  renamed
}

// Whether `name`, the owner of a dot-named function, names a type alias in
// the current scope.
func dotOwnerIsAlias(tbl: in SymbolTable, name: in String): Bool {
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKTypeAlias(_) -> return true
      case _ -> ()
    }
  }
  false
}

// Names whose typecheck behaviour is owned by `codegenBuiltinType` (see
// `typechecker_exprs.l`).  Stdlib imports must not register signatures
// under these names because their codegen path expects the polymorphic
// `TyError`-typed surface.
//
// IMPORTANT: keep this list in lock-step with `codegenBuiltinType`'s
// `name == "<...>" { ... return Some(...) }` arms in
// `typechecker_exprs.l`.  The two functions form an implicit contract —
// every name that `codegenBuiltinType` returns a polymorphic signature
// for must appear here, otherwise an imported stdlib `pub func` with
// the same simple name will shadow the builtin and tighten the call's
// argument type from `TyError` (any) to the stdlib's concrete shape
// (#1384).
func isCodegenBuiltinName(name: in String): Bool {
  name == "println" or name == "print" or name == "toString" or name == "panic" or name == "default" or name == "expect" or
    name == "assert" or
    name == "format1" or
    name == "format2" or
    name == "format3" or
    name == "format4"
}

// The bare names every backend's `lowerBuiltinOrStaticCall{Msil,}`/
// `lowerCallEx` dispatcher intercepts UNCONDITIONALLY, before any name
// resolution: true language built-ins with no ordinary Lyric signature
// (`println`'s argument is polymorphic over any type, `panic` returns
// `Never`, …), audited in D-progress-1004 (#7465/#7508) and never
// redeclarable by a `func`/`pub func` outside `Std.*` — see
// `checkReservedBuiltinFuncDecl`. Distinct from `isCodegenBuiltinName`
// above (which only guards STDLIB IMPORTS from shadowing the polymorphic
// checker type) and from the larger "stdlib kernel function with the same
// semantics" intercept set (`newList`, `mapGet`, `tryGetValue`, `newSet`,
// `dictGetKeys`, `dictGetValues`, `hostGetCommandLineArgs`,
// `stringToUtf8Bytes`, `charToString`, `catch`, `newListWithCapacity`),
// which a non-`Std` package MAY freely redeclare — the backends resolve a
// bare/qualified call to that name against the real declaration instead of
// the intrinsic (`hasFuncOverrideMsil`/`hasFuncOverrideJvm`/
// `hasFuncOverrideNative`).
func isReservedBuiltinFuncName(name: in String): Bool {
  // Every name `codegenBuiltinType` types polymorphically is also
  // intercepted by the backends, so the one list lives in
  // `isCodegenBuiltinName`; the names below are backend intrinsics with no
  // polymorphic checker signature (#7682).
  isCodegenBuiltinName(name) or name == "hashCode" or name == "__lyric_protected_wait" or
    name == "__lyric_protected_notify" or
    name == "externAsObject"
}

func isStdOriginPkg(pkg: in String): Bool {
  pkg == "Std" or pkg.startsWith("Std.")
}

// T0140 (#7508): a NON-`Std.*` package's own `func`/`pub func` declaration
// named one of `isReservedBuiltinFuncName`'s reserved built-ins is rejected
// at declaration time, rather than being silently captured by the same-named
// backend intrinsic at every call site (the pre-fix behaviour) or, absent
// the intrinsic, misdispatched by a hand-rolled per-call override check.
// `Std.*` keeps the exemption every reserved name it legitimately
// re-implements already relies on (e.g. `Std.Console.println`/`print`,
// reachable only qualified — bare `println`/`print` always mean the
// intrinsic, per `isCodegenBuiltinName`'s import-time skip above).
func checkReservedBuiltinFuncDecl(
  diag: in List[Diagnostic],
  isImported: in Bool,
  originPkg: in String,
  name: in String,
  span: in Span,
): Unit {
  if (not isImported) and isReservedBuiltinFuncName(name) and not isStdOriginPkg(originPkg) {
    diag.add(
      errorDiagnostic(
        "T0140",
        "'" + name + "' is a reserved built-in name and cannot be declared as a function; rename it",
        span
      )
    )
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7a. Method-signature space (docs/59 A4).
// ─────────────────────────────────────────────────────────────────────────────
// Build the *call-facing* ResolvedSignature for a method attached to a type:
// the leading `self` param (records inject one in the parser) is dropped so
// `sig.params` aligns 1:1 with a call site's argument list; `impl` block and
// interface members never carry a `self` param (the receiver is implicit).
// Owner generics are pushed alongside the method's own generics so a `Box[T]`
// method's `T`-typed params resolve to `TyVar("T")` (substitutable at the call
// site from the receiver's type args).  Type-reference diagnostics go to a
// scratch list: declaration-position validation of member signatures is
// `checkMemberSigTypes`'s job (T4), and re-reporting here would duplicate it.
func resolveMethodSigParts(
  tbl: in SymbolTable,
  pkgName: in String,
  ownerGenerics: in List[String],
  fnGenerics: in Option[GenericParams],
  fnParams: in List[Param],
  fnRet: in Option[TypeExpr],
  fnIsAsync: in Bool,
  fnIsPure: in Bool,
  fnIsIo: in Bool,
  fnIsEntry: in Bool,
  span: in Span,
): ResolvedSignature {
  val genericNames = extractGenericNames(fnGenerics)
  val ctx = newGenericContext()
  if ownerGenerics.count > 0 {
    gctxPush(ctx, ownerGenerics)
  }
  if genericNames.count > 0 {
    gctxPush(ctx, genericNames)
  }
  val scratch: List[Diagnostic] = newList()
  val params: List[ResolvedParam] = newList()
  var i = 0
  while i < fnParams.count {
    val p = fnParams[i]
    if not (i == 0 and p.name == "self") {
      params.add(
        ResolvedParam(
          name = p.name,
          ty = resolveType(tbl, ctx, scratch, p.ty),
          mode = p.mode,
          hasDefault = match p.dflt { case None -> false; case Some(d) -> not isUnexportedDefaultCall(d) },
          span = p.span,
          tyExpr = Some(value = p.ty),
          defaultInert = match p.dflt { case None -> false; case Some(d) -> exprIsInert(d) },
          defaultUnavailable = match p.dflt { case None -> false; case Some(d) -> isUnexportedDefaultCall(d) }
        )
      )
    }
    i = i + 1
  }
  val returnTy = match fnRet { case None -> TyPrim(pt = PtUnit); case Some(te) -> resolveType(tbl, ctx, scratch, te) }
  val noBounds: List[ResolvedBound] = newList()
  ResolvedSignature(
    generics = genericNames,
    bounds = noBounds,
    params = params,
    returnTy = returnTy,
    isAsync = fnIsAsync,
    isHot = false,
    isGenerator = false,
    originPackage = pkgName,
    span = span,
    isPure = fnIsPure,
    isIo = fnIsIo,
    isEntry = fnIsEntry,
    isExternFunc = false
  )
}

// The simple name of a resolved user type (empty for non-`TyUser`).
func simpleTypeNameOf(t: in Type): String {
  match unrefine(t) {
    case TyUser(_, nm, _) -> nm
    case _ -> ""
  }
}

func addRecordMethodSigs(tbl: in SymbolTable, pkgName: in String, decl: in RecordDecl): Unit {
  match symTableTryFindOne(tbl, decl.name) {
    case Some(sym) -> match symbolTypeIdOpt(sym) {
      case Some(tid) -> {
        val ownerGen = recordDeclGenericNames(decl)
        var m = 0
        while m < decl.members.count {
          match decl.members[m] {
            case RMFunc(fn) -> symTableAddMethodSig(
              tbl,
              MethodEntry(
                owner = tid,
                ownerName = decl.name,
                ownerGenerics = ownerGen,
                name = fn.name,
                sig = resolveMethodSigParts(
                  tbl,
                  pkgName,
                  ownerGen,
                  fn.generics,
                  fn.params,
                  fn.ret,
                  fn.isAsync,
                  fnHasAnnotation(fn, "pure"),
                  fnHasAnnotation(fn, "io"),
                  false,
                  fn.span
                )
              )
            )
            case _ -> {
            }
          }
          m = m + 1
        }
      }
      case None -> {
      }
    }
    case None -> {
    }
  }
}

// Collect every method signature reachable through a value receiver — record
// body methods, `impl` block methods (keyed by the resolved target type), and
// interface members — into the symbol table's method-signature space.  Runs in
// the same per-package T3 loops as `addSigsFromItems`, so each package's
// member types resolve under its own scope.
func addMethodSigsFromItems(tbl: in SymbolTable, items: in List[Item], pkgName: in String): Unit {
  val scratch: List[Diagnostic] = newList()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IRecord(decl) -> addRecordMethodSigs(tbl, pkgName, decl)
      case IExposedRec(decl) -> addRecordMethodSigs(tbl, pkgName, decl)
      case IImpl(decl) -> {
        val implGenerics = extractGenericNames(decl.generics)
        val ctx = newGenericContext()
        if implGenerics.count > 0 {
          gctxPush(ctx, implGenerics)
        }
        val targetTy = resolveType(tbl, ctx, scratch, decl.target)
        match typeIdOfType(targetTy) {
          case Some(tid) -> {
            var m = 0
            while m < decl.members.count {
              match decl.members[m] {
                case IMplFunc(fn) -> symTableAddMethodSig(
                  tbl,
                  MethodEntry(
                    owner = tid,
                    ownerName = simpleTypeNameOf(targetTy),
                    ownerGenerics = implGenerics,
                    name = fn.name,
                    sig = resolveMethodSigParts(
                      tbl,
                      pkgName,
                      implGenerics,
                      fn.generics,
                      fn.params,
                      fn.ret,
                      fn.isAsync,
                      fnHasAnnotation(fn, "pure"),
                      fnHasAnnotation(fn, "io"),
                      false,
                      fn.span
                    )
                  )
                )
                case _ -> {
                }
              }
              m = m + 1
            }
          }
          case None -> {
          }
        }
      }
      case IInterface(decl) -> {
        match symTableTryFindOne(tbl, decl.name) {
          case Some(sym) -> match sym.kind {
            case DKInterface(tid, _) -> {
              val ifaceGen = extractGenericNames(decl.generics)
              var m = 0
              while m < decl.members.count {
                match decl.members[m] {
                  case IMSig(sig) -> symTableAddMethodSig(
                    tbl,
                    MethodEntry(
                      owner = tid,
                      ownerName = decl.name,
                      ownerGenerics = ifaceGen,
                      name = sig.name,
                      sig = resolveMethodSigParts(
                        tbl,
                        pkgName,
                        ifaceGen,
                        sig.generics,
                        sig.params,
                        sig.ret,
                        sig.isAsync,
                        annotationsHaveName(sig.annotations, "pure"),
                        false,
                        false,
                        sig.span
                      )
                    )
                  )
                  case IMFunc(fn) -> symTableAddMethodSig(
                    tbl,
                    MethodEntry(
                      owner = tid,
                      ownerName = decl.name,
                      ownerGenerics = ifaceGen,
                      name = fn.name,
                      sig = resolveMethodSigParts(
                        tbl,
                        pkgName,
                        ifaceGen,
                        fn.generics,
                        fn.params,
                        fn.ret,
                        fn.isAsync,
                        fnHasAnnotation(fn, "pure"),
                        fnHasAnnotation(fn, "io"),
                        false,
                        fn.span
                      )
                    )
                  )
                  case _ -> {
                  }
                }
                m = m + 1
              }
            }
            case _ -> {
            }
          }
          case None -> {
          }
        }
      }
      // #6483: protected-type `entry`/`func` members register into the same
      // method-sig space as record/impl/interface members, so a sibling member
      // called by bare name from another member body resolves through the
      // ECall member-callee fallback (#1722/#6435), and `self.member(...)`
      // resolves through the method space.  Both backends already register
      // and lower these calls (`methodTokens` `<cls>/<name>` on MSIL,
      // `funcSigs` `<cls>#<name>` + `selfClass` on JVM); only the checker
      // was missing.  The entry/func lock wrappers are reentrant on both
      // targets (CLR `Monitor`, JVM object monitors), so a sibling call
      // through the locked public method is safe.
      case IProtected(decl) -> {
        match symTableTryFindOne(tbl, decl.name) {
          case Some(sym) -> match sym.kind {
            case DKProtected(tid, _) -> {
              val protGen = extractGenericNames(decl.generics)
              val noGenerics: Option[GenericParams] = None
              var m = 0
              while m < decl.members.count {
                match decl.members[m] {
                  case PMEntry(ed) -> symTableAddMethodSig(
                    tbl,
                    MethodEntry(
                      owner = tid,
                      ownerName = decl.name,
                      ownerGenerics = protGen,
                      name = ed.name,
                      sig = resolveMethodSigParts(
                        tbl,
                        pkgName,
                        protGen,
                        noGenerics,
                        ed.params,
                        ed.ret,
                        false,
                        false,
                        false,
                        true,
                        ed.span
                      )
                    )
                  )
                  case PMFunc(fn) -> symTableAddMethodSig(
                    tbl,
                    MethodEntry(
                      owner = tid,
                      ownerName = decl.name,
                      ownerGenerics = protGen,
                      name = fn.name,
                      sig = resolveMethodSigParts(
                        tbl,
                        pkgName,
                        protGen,
                        fn.generics,
                        fn.params,
                        fn.ret,
                        fn.isAsync,
                        fnHasAnnotation(fn, "pure"),
                        fnHasAnnotation(fn, "io"),
                        false,
                        fn.span
                      )
                    )
                  )
                  case _ -> {
                  }
                }
                m = m + 1
              }
            }
            case _ -> {
            }
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8a. impl/interface conformance (#1486).
// ─────────────────────────────────────────────────────────────────────────────
// Replace every `TySelf` occurrence in `t` with `selfTy`, used when matching
// interface parameter/return types against a concrete impl.
// `Self` is the owning type inside a record's or impl's method bodies — for
// its parameters as for its return — so a `Self` parameter passes where that
// type is expected, e.g. as the argument of a bare sibling call, whose
// signature is registered with `Self` already substituted (#7704).
func substitutesSelfParams(params: in List[ResolvedParam], selfTy: in Type): List[ResolvedParam] {
  val substituted: List[ResolvedParam] = newList()
  var i = 0
  while i < params.count {
    val rp = params[i]
    substituted.add(
      ResolvedParam(
        name = rp.name,
        ty = substitutesSelf(rp.ty, selfTy),
        mode = rp.mode,
        hasDefault = rp.hasDefault,
        span = rp.span,
        tyExpr = rp.tyExpr,
        defaultInert = rp.defaultInert,
        defaultUnavailable = rp.defaultUnavailable
      )
    )
    i = i + 1
  }
  substituted
}

func substitutesSelf(t: in Type, selfTy: in Type): Type {
  match t {
    case TySelf -> selfTy
    case TyUser(id, name, args) -> {
      val na: List[Type] = newList()
      var i = 0
      while i < args.count {
        na.add(substitutesSelf(args[i], selfTy))
        i = i + 1
      }
      TyUser(id = id, name = name, args = na)
    }
    case TyNullable(inner) -> TyNullable(inner = substitutesSelf(inner, selfTy))
    case TySlice(elem) -> TySlice(element = substitutesSelf(elem, selfTy))
    case TyArray(sz, elem, sv) -> TyArray(size = sz, element = substitutesSelf(elem, selfTy), sizeVar = sv)
    case TyTuple(elems) -> {
      val ne: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ne.add(substitutesSelf(elems[i], selfTy))
        i = i + 1
      }
      TyTuple(elems = ne)
    }
    case TyFunction(ps, ret, isA) -> {
      val np: List[Type] = newList()
      var i = 0
      while i < ps.count {
        np.add(substitutesSelf(ps[i], selfTy))
        i = i + 1
      }
      TyFunction(params = np, ret = substitutesSelf(ret, selfTy), isAsync = isA)
    }
    case _ -> t
  }
}

func findInterfaceDecl(tbl: in SymbolTable, name: in String): Option[InterfaceDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKInterface(_, d) -> {
        if tbl.symbols[i].name == name {
          return Some(value = d)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

func findImplMethod(decl: in ImplDecl, name: in String): Option[FunctionDecl] {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        if fn.name == name {
          return Some(value = fn)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// Structural conformance for an `impl Iface for Target { … }`.  Checks:
//   T0098 — abstract method missing from the impl.
//   T0099 — parameter arity mismatch.
//   T0106 — parameter type mismatch (C11).
//   T0107 — return type mismatch (C11).
// `Self` in the interface is substituted with the resolved impl target type so
// that `func method(other: Self): Bool` matches `func method(other: MyType): Bool`.
// Default methods (`IMFunc`) are optional to OVERRIDE; they are skipped here
// (no arity/type re-validation of a matching override) because an impl that
// omits one gets it for free — `Lyric.ImplDefaults.inheritDefaultsFile`
// (#6433) copies the interface's own body into the impl as a real member
// before this check runs, same-file interfaces only.
// Cross-package interfaces not found in the local symbol table are silently
// skipped — cross-package conformance is enforced by the restoring package's
// own type-check pass.
// `te`, written in the declaration of interface `iface`, resolved in the
// interface's declaring package.
func resolveIfaceType(
  tbl: in SymbolTable,
  iface: in Option[Symbol],
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  te: in TypeExpr,
): Type {
  match iface {
    case Some(isym) -> if isym.originPackage.length > 0 {
      val saved = enterDeclaringScope(tbl, isym)
      val t = resolveType(tbl, ctx, diag, te)
      restoreScope(tbl, saved)
      return t
    }
    case None -> ()
  }
  resolveType(tbl, ctx, diag, te)
}

func listTake(xs: in List[String], n: in Int): List[String] {
  val taken: List[String] = newList()
  var i = 0
  while i < n and i < xs.count {
    taken.add(xs[i])
    i = i + 1
  }
  taken
}

// T0145 (#7704): an impl for a generic type applies to every instantiation of
// it — both backends attach the methods to the type's single generic class, so
// its target's type arguments must be the impl's own type parameters, each
// named once (`impl[T] I for Box[T]`, `impl[K, V] I for Pair[V, K]`), and every
// impl type parameter must appear among them.  A concrete argument
// (`impl I for Box[Int]`) would need a separate class per instantiation, and an
// impl type parameter the target never names has no instantiation to take its
// type from.
func checkImplGenericTarget(diag: in List[Diagnostic], decl: in ImplDecl): Unit {
  val implGenerics = extractGenericNames(decl.generics)
  val named: List[String] = newList()
  match decl.target.kind {
    case TGenericApp(_, args) -> {
      var i = 0
      while i < args.count {
        val argName = match args[i] {
          case TAType(ty) -> match ty.kind {
            case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
            case _ -> ""
          }
          case TAValue(_) -> ""
        }
        if argName == "" or not listContainsStr(implGenerics, argName) or listContainsStr(named, argName) {
          diag.add(
            errorDiagnostic(
              "T0145",
              "an impl for a generic type must pass the impl's own type parameters, each once, as the type's arguments " +
                "(e.g. `impl[T] I for Box[T]`); an impl for a single instantiation is not supported",
              decl.span
            )
          )
          return
        }
        named.add(argName)
        i = i + 1
      }
    }
    case _ -> ()
  }
  var g = 0
  while g < implGenerics.count {
    if not listContainsStr(named, implGenerics[g]) {
      diag.add(
        errorDiagnostic(
          "T0145",
          "impl type parameter '" + implGenerics[g] + "' is not an argument of the impl's target type " +
            "(e.g. `impl[T] I for Box[T]`)",
          decl.span
        )
      )
      return
    }
    g = g + 1
  }
}

func checkImplConformance(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in ImplDecl): Unit {
  val segs = decl.iface.head.segments
  if segs.count == 0 {
    return
  }
  val ifaceName = segs[segs.count - 1]
  // The interface the impl names, qualified or bare; its own signature types
  // resolve in its declaring package, not in the implementing file's scope
  // (whose import rule need not make them visible, docs/01 §9.2).
  val ifaceSym = if segs.count > 1 {
    symTableTryFindInPackage(tbl, modulePathJoin(listTake(segs, segs.count - 1)), ifaceName)
  } else {
    symTableTryFindOne(tbl, ifaceName)
  }
  val ifacePkgName = match ifaceSym { case Some(isym) -> isym.originPackage; case None -> "" }
  val found = match ifaceSym {
    case Some(isym) -> match isym.kind {
      case DKInterface(_, d) -> Some(value = d)
      case _ -> findInterfaceDecl(tbl, ifaceName)
    }
    case None -> findInterfaceDecl(tbl, ifaceName)
  }
  match found {
    case None -> {
    }
    case Some(ifaceDecl) -> {
      // The impl's own type parameters (`impl[T] I for Box[T]`) are in scope
      // for its target and for its methods' signatures (#7704).
      val ctx = declGenericContext(decl.generics)
      val selfTy = resolveType(tbl, ctx, diag, decl.target)
      val ifaceGenNames = extractGenericNames(ifaceDecl.generics)
      val ifaceArgTys: List[Type] = newList()
      for ia in decl.iface.args {
        match ia {
          case TAType(te) -> ifaceArgTys.add(resolveType(tbl, ctx, diag, te))
          case TAValue(_) -> ifaceArgTys.add(TyError)
        }
      }
      if ifaceArgTys.count != ifaceGenNames.count {
        diag.add(
          errorDiagnostic(
            "T0216",
            "interface '" + ifaceName + "' takes " + toString(ifaceGenNames.count) + " type argument(s) but the impl gives " +
              toString(ifaceArgTys.count),
            decl.span
          )
        )
        return
      }
      if ifaceGenNames.count > 0 {
        diag.add(
          errorDiagnostic(
            "T0217",
            "an impl of the generic interface '" + ifaceName +
              "' is not supported by the code generators yet: declare a non-generic interface for each instantiation (#7791)",
            decl.span
          )
        )
      }
      var i = 0
      while i < ifaceDecl.members.count {
        match ifaceDecl.members[i] {
          case IMSig(sig) -> {
            match findImplMethod(decl, sig.name) {
              case None -> diag.add(
                errorDiagnostic(
                  "T0098",
                  "impl of interface '" + ifaceName + "' is missing method '" + sig.name + "'",
                  decl.span
                )
              )
              case Some(fn) -> {
                if annotationsHaveName(sig.annotations, "pure") and not fnHasAnnotation(fn, "pure") {
                  diag.add(
                    errorDiagnostic(
                      "T0192",
                      "impl method '" + sig.name + "' implements '@pure' method '" + ifaceName + "." + sig.name +
                        "' and must itself be '@pure'",
                      fn.span
                    )
                  )
                }
                if fn.params.count == sig.params.count {
                  reportImplDefaultMismatches(
                    tbl,
                    diag,
                    ifacePkgName,
                    symTableScopePkg(tbl),
                    ifaceName,
                    sig.name,
                    sig.params,
                    fn.params
                  )
                }
                val sigGenNames = extractGenericNames(sig.generics)
                val fnGenNames = extractGenericNames(fn.generics)
                val sigGenVars: List[Type] = newList()
                for gn in sigGenNames {
                  sigGenVars.add(TyVar(name = gn))
                }
                if fn.params.count != sig.params.count {
                  diag.add(
                    errorDiagnostic(
                      "T0099",
                      "impl method '" + sig.name + "' has " + toString(fn.params.count) + " parameter(s) but interface '" + ifaceName +
                        "' declares " +
                        toString(sig.params.count),
                      fn.span
                    )
                  )
                } else {
                  // C11: check each parameter type matches (with Self substitution).
                  // The interface's own type parameters and the method's are in
                  // scope on the interface side; the former take the impl's
                  // interface arguments, and the impl method's own parameters
                  // are renamed to the interface method's (#7791).
                  val ictx = newGenericContext()
                  gctxPush(ictx, ifaceGenNames)
                  gctxPush(ictx, sigGenNames)
                  gctxPush(ctx, fnGenNames)
                  var pi = 0
                  while pi < sig.params.count {
                    val ifacePTy = substitutesSelf(
                      substituteTyVars(
                        resolveIfaceType(tbl, ifaceSym, ictx, diag, sig.params[pi].ty),
                        ifaceGenNames,
                        ifaceArgTys
                      ),
                      selfTy
                    )
                    val implPTy = substitutesSelf(
                      substituteTyVars(resolveType(tbl, ctx, diag, fn.params[pi].ty), fnGenNames, sigGenVars),
                      selfTy
                    )
                    if not argSatisfiesParam(tbl, ifacePTy, implPTy) {
                      diag.add(
                        errorDiagnostic(
                          "T0106",
                          "impl method '" + sig.name + "' parameter '" + sig.params[pi].name + "' has type " +
                            renderTypeExpr(fn.params[pi].ty, implPTy) +
                            " but interface expects " +
                            renderTypeExpr(sig.params[pi].ty, ifacePTy),
                          fn.params[pi].span
                        )
                      )
                    }
                    pi = pi + 1
                  }
                  // C11: check return type matches (with Self substitution).
                  val ifaceRetTy = substitutesSelf(
                    substituteTyVars(
                      match sig.ret {
                        case None -> TyPrim(pt = PtUnit)
                        case Some(te) -> resolveIfaceType(tbl, ifaceSym, ictx, diag, te)
                      },
                      ifaceGenNames,
                      ifaceArgTys
                    ),
                    selfTy
                  )
                  val implRetTy = substitutesSelf(
                    substituteTyVars(
                      match fn.ret {
                        case None -> TyPrim(pt = PtUnit)
                        case Some(te) -> resolveType(tbl, ctx, diag, te)
                      },
                      fnGenNames,
                      sigGenVars
                    ),
                    selfTy
                  )
                  if not argSatisfiesParam(tbl, ifaceRetTy, implRetTy) {
                    diag.add(
                      errorDiagnostic(
                        "T0107",
                        "impl method '" + sig.name + "' returns " + renderOptTypeExpr(fn.ret, implRetTy) + " but interface '" + ifaceName +
                          "' declares return type " +
                          renderOptTypeExpr(sig.ret, ifaceRetTy),
                        fn.span
                      )
                    )
                  }
                  gctxPop(ctx)
                }
              }
            }
          }
          // An `impl` method overriding an interface default method.
          case IMFunc(ifn) -> match findImplMethod(decl, ifn.name) {
            case Some(fn) -> {
              if fnHasAnnotation(ifn, "pure") and not fnHasAnnotation(fn, "pure") {
                diag.add(
                  errorDiagnostic(
                    "T0192",
                    "impl method '" + ifn.name + "' overrides '@pure' method '" + ifaceName + "." + ifn.name +
                      "' and must itself be '@pure'",
                    fn.span
                  )
                )
              }
              if fn.params.count == ifn.params.count {
                reportImplDefaultMismatches(
                  tbl,
                  diag,
                  ifacePkgName,
                  symTableScopePkg(tbl),
                  ifaceName,
                  ifn.name,
                  ifn.params,
                  fn.params
                )
              }
            }
            case None -> ()
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
  }
}

// T0161 (warning): a parameter of an `impl` method whose default is not the
// one the interface member declares for it, or which only one of the two
// gives a default.  A call takes the defaults of the declaration it resolves
// through (docs/01 §"Default arguments"), so a call through the interface
// type and a call on the concrete type would fill the argument differently
// (#7828).  `ifaceParams` and `implParams` have the same count.
func reportImplDefaultMismatches(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  ifacePkg: in String,
  implPkg: in String,
  ifaceName: in String,
  methodName: in String,
  ifaceParams: in List[Param],
  implParams: in List[Param],
): Unit {
  var i = 0
  while i < implParams.count {
    val ip = ifaceParams[i]
    val mp = implParams[i]
    val subject = "parameter '" + mp.name + "' of impl method '" + methodName + "'"
    val through = "a call on a value of interface type '" + ifaceName + "'"
    val why = match ip.dflt {
      case Some(ie) -> match mp.dflt {
        // A default declared in a package restored from its contract
        // metadata is a call to the thunk compiled from it (#7827); its
        // expression is not known here, so it is not compared.
        case Some(me) -> if sameDefaultExpr(tbl, ifacePkg, implPkg, ie, me) or isDefaultThunkCall(ie) or isDefaultThunkCall(me) {
          ""
        } else {
          subject + " has a different default from the one interface '" + ifaceName + "' declares; " + through +
            " uses the interface's default and a call on the implementing type uses this one"
        }
        case None -> subject + " has no default, but interface '" + ifaceName +
          "' declares one; " +
          through +
          " uses the interface's default and a call on the implementing type must pass the argument"
      }
      case None -> match mp.dflt {
        case Some(_) -> subject + " has a default that interface '" + ifaceName +
          "' does not declare; " +
          through +
          " must pass the argument and a call on the implementing type uses this default"
        case None -> ""
      }
    }
    if why.length > 0 {
      diag.add(warningDiagnostic("T0161", why + " (declare the same default in both)", mp.span))
    }
    i = i + 1
  }
}

// True when two defaults mean the same value: both fold to the same integer
// constant, each with its names read in its own package (`1 + 1` and `2`
// agree, a `LIMIT` of one package and a different `LIMIT` of another do not),
// or they are written the same way (their canonical, span-free renderings,
// `Lyric.Fmt.exprInline`, agree, ignoring enclosing parentheses) and every
// name in them resolves to the same declaration from both packages.  Every
// expression form compares, so two `if`, `match` or interpolated defaults
// written alike are the same default (#8100).
func sameDefaultExpr(tbl: in SymbolTable, ifacePkg: in String, implPkg: in String, a: in Expr, b: in Expr): Bool {
  val x = stripExprParens(a)
  val y = stripExprParens(b)
  match tryFoldIntInPackage(tbl, ifacePkg, x) {
    case FoldOk(xv) -> match tryFoldIntInPackage(tbl, implPkg, y) { case FoldOk(yv) -> return xv == yv; case _ -> () }
    case _ -> ()
  }
  if Fmt.exprInline(0, x) != Fmt.exprInline(0, y) {
    return false
  }
  val xOrigins: List[String] = newList()
  val yOrigins: List[String] = newList()
  collectDefaultNameOrigins(tbl, ifacePkg, x, xOrigins)
  collectDefaultNameOrigins(tbl, implPkg, y, yOrigins)
  if xOrigins.count != yOrigins.count {
    return false
  }
  var i = 0
  while i < xOrigins.count {
    if xOrigins[i] != yOrigins[i] {
      return false
    }
    i = i + 1
  }
  true
}

// The declaration each bare name in a default resolves to from `pkg`, in
// source order, as `name@package@declaration site`; a name nothing declares
// contributes its bare name.  Only the forms a default is usually built from
// are walked: any other form's names are left to the text comparison.
func collectDefaultNameOrigins(tbl: in SymbolTable, pkg: in String, e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> if path.segments.count == 1 {
      val name = path.segments[0]
      val found = if pkg.length > 0 { symTableTryFindInPackage(tbl, pkg, name) } else { symTableTryFindOne(tbl, name) }
      match found {
        case Some(sym) -> acc.add(name + "@" + sym.originPackage + "@" + recordCopySiteKey(sym.declSpan))
        case None -> acc.add(name)
      }
    }
    case EParen(inner) -> collectDefaultNameOrigins(tbl, pkg, inner, acc)
    case EPrefix(_, operand) -> collectDefaultNameOrigins(tbl, pkg, operand, acc)
    case EBinop(_, lhs, rhs) -> {
      collectDefaultNameOrigins(tbl, pkg, lhs, acc)
      collectDefaultNameOrigins(tbl, pkg, rhs, acc)
    }
    case EMember(receiver, _) -> collectDefaultNameOrigins(tbl, pkg, receiver, acc)
    case ETuple(es) -> {
      for x in es {
        collectDefaultNameOrigins(tbl, pkg, x, acc)
      }
    }
    case EList(es) -> {
      for x in es {
        collectDefaultNameOrigins(tbl, pkg, x, acc)
      }
    }
    case ECall(fn, args) -> {
      collectDefaultNameOrigins(tbl, pkg, fn, acc)
      for arg in args {
        match arg {
          case CAPositional(v) -> collectDefaultNameOrigins(tbl, pkg, v, acc)
          case CANamed(_, v, _) -> collectDefaultNameOrigins(tbl, pkg, v, acc)
        }
      }
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. Declaration-position type-reference validation (#1228).
// ─────────────────────────────────────────────────────────────────────────────
// Function signatures already surface unknown type names via
// `resolveFunctionSig`.  Record / exposed-record / opaque / protected fields,
// union case fields, interface member signatures, member functions, type-alias
// targets, and module-level val/const annotations were never resolved unless a
// body expression happened to touch them, so a misspelled or un-imported type
// silently degraded to `System.Object` and surfaced as a codegen failure far
// from the declaration.  Resolve every declared type reference here — the
// resolved types are discarded; only the T0010/T0013/T0014 diagnostics matter.
func declGenericContext(generics: in Option[GenericParams]): GenericContext {
  val names = extractGenericNames(generics)
  val ctx = newGenericContext()
  if names.count > 0 {
    gctxPush(ctx, names)
  }
  ctx
}

// Validate the parameter and return types of a member signature, with the
// owner type's generic parameters (`outerGenerics`) and the member's own
// generic parameters both in scope.
func checkMemberSigTypes(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  outerGenerics: in Option[GenericParams],
  generics: in Option[GenericParams],
  params: in List[Param],
  ret: in Option[TypeExpr],
): Unit {
  val ctx = declGenericContext(outerGenerics)
  val names = extractGenericNames(generics)
  if names.count > 0 {
    gctxPush(ctx, names)
  }
  var i = 0
  while i < params.count {
    val _ = resolveType(tbl, ctx, diag, params[i].ty)
    i = i + 1
  }
  match ret {
    case Some(te) -> {
      val _ = resolveType(tbl, ctx, diag, te)
    }
    case None -> {
    }
  }
}

func checkRecordDeclTypes(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in RecordDecl): Unit {
  val ctx = declGenericContext(decl.generics)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(field) -> {
        val _ = resolveType(tbl, ctx, diag, field.ty)
      }
      case RMFunc(fn) -> {
        checkMemberSigTypes(tbl, diag, decl.generics, fn.generics, fn.params, fn.ret)
        checkMethodGenericByRefParams(diag, decl.name, fn)
      }
      case RMInvariant(_) -> {
      }
    }
    i = i + 1
  }
}

// T0214: a record method's own type parameter is erased in its body, so an
// `out` or `inout` parameter typed by it would take a reference to a caller's
// variable of the concrete type where the method expects one to an erased
// value, which a backend with reified value types cannot pass (#8241).  A free
// generic function is specialised per type argument and has no such limit.
func checkMethodGenericByRefParams(diag: in List[Diagnostic], owner: in String, fn: in FunctionDecl): Unit {
  val own: List[String] = newList()
  match fn.generics {
    case Some(g) -> {
      for gp in g.params {
        match gp {
          case GPType(nm, _) -> own.add(nm)
          case GPValue(_, _, _) -> ()
        }
      }
    }
    case None -> ()
  }
  if own.count == 0 {
    return
  }
  for p in fn.params {
    val byRef = match p.mode { case PMIn -> false; case PMOut -> true; case PMInout -> true }
    if byRef {
      val hit = typeExprNamesAny(p.ty, own)
      if hit != "" {
        diag.add(
          errorDiagnostic(
            "T0214",
            "parameter '" + p.name + "' of method '" + fn.name + "' of '" + owner + "' is passed by reference (" +
              (match p.mode { case PMOut -> "out"; case _ -> "inout" }) +
              ") and its type mentions the method's own type parameter '" +
              hit +
              "'; a method's type parameters are erased, so declare '" +
              fn.name +
              "' as a free generic function taking the record, or take the value with `in` and return the result",
            p.span
          )
        )
      }
    }
  }
}

// The first of `names` that `te` mentions as a type name, or "".
func typeExprNamesAny(te: in TypeExpr, names: in List[String]): String {
  match te.kind {
    case TRef(path) -> if path.segments.count == 1 and names.contains(path.segments[0]) { path.segments[0] } else { "" }
    case TGenericApp(head, args) -> {
      if head.segments.count == 1 and names.contains(head.segments[0]) {
        return head.segments[0]
      }
      for a in args {
        match a {
          case TAType(t) -> {
            val h = typeExprNamesAny(t, names)
            if h != "" {
              return h
            }
          }
          case TAValue(_) -> ()
        }
      }
      ""
    }
    case TArray(_, element) -> typeExprNamesAny(element, names)
    case TSlice(element) -> typeExprNamesAny(element, names)
    case TTuple(types) -> {
      for t in types {
        val h = typeExprNamesAny(t, names)
        if h != "" {
          return h
        }
      }
      ""
    }
    case TNullable(inner) -> typeExprNamesAny(inner, names)
    case TFunction(ps, ret) -> {
      for t in ps {
        val h = typeExprNamesAny(t, names)
        if h != "" {
          return h
        }
      }
      typeExprNamesAny(ret, names)
    }
    case TParen(inner) -> typeExprNamesAny(inner, names)
    case _ -> ""
  }
}

// `Plain` is computed from a type's structure (D155), so a declaration cannot
// ask for it: it is valid in a `where` clause only.
func checkNoPlainDerive(diag: in List[Diagnostic], anns: in List[Annotation]): Unit {
  for ann in anns {
    if ann.name.segments.count == 1 and ann.name.segments[0] == "derive" {
      for a in ann.args {
        match a {
          case ABare(nm, sp) -> if isPlainMarker(nm) {
            diag.add(
              errorDiagnostic(
                "T0172",
                "'Plain' cannot be derived: the compiler computes it from a type's structure, and it is valid only in a 'where' clause",
                sp
              )
            )
          }
          case _ -> ()
        }
      }
    }
  }
}

// A record may derive `Add` and `Sub` only as component-wise operators on a
// homogeneous numeric record (D155): every field has the same numeric
// primitive type, the record is not generic, and it has no `invariant:` (the
// component-wise result is built field by field and would not be re-checked).
// `Mul`, `Div` and `Mod` are not component-wise vector operations; scaling and
// products are methods.  T0152 otherwise.
func checkRecordArithDerives(diag: in List[Diagnostic], anns: in List[Annotation], decl: in RecordDecl): Unit {
  val derives = extractDerives(anns)
  for d in derives {
    if d == "Mul" or d == "Div" or d == "Mod" {
      diag.add(
        errorDiagnostic(
          "T0152",
          "record '" + decl.name + "' cannot derive " + d +
            ": a record derives only Add and Sub, component-wise; write scaling and products as methods",
          decl.span
        )
      )
    } else if d == "Add" or d == "Sub" {
      match homogeneousNumericProblem(decl) {
        case Some(why) -> diag.add(
          errorDiagnostic(
            "T0152",
            "record '" + decl.name + "' cannot derive " + d + ": " + why,
            decl.span
          )
        )
        case None -> ()
      }
    }
  }
}

// A derived `equals`, `hash`, `show` or ordering reads each field by the
// field type's own `==` or text, and no such code exists for an array (D167):
// `==` on an array compares element by element, but derived code would compare
// the array's reference.  So a type with a field that holds an array anywhere
// (directly, in an `Option`, a tuple, a collection, or a nested record or
// union) derives none of them (T0159); `Add` and `Sub` have their own rule
// (T0152).
func checkArrayFieldDerives(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  anns: in List[Annotation],
  typeName: in String,
  generics: in Option[GenericParams],
  fieldTypes: in List[TypeExpr],
  span: in Span,
): Unit {
  val derives = extractDerives(anns)
  if derives.count == 0 {
    return
  }
  val ctx = declGenericContext(generics)
  val scratch: List[Diagnostic] = newList()
  var hasArray = false
  for ft in fieldTypes {
    val seen: List[Int] = newList()
    if typeHoldsArray(tbl, resolveType(tbl, ctx, scratch, ft), seen) {
      hasArray = true
    }
  }
  if not hasArray {
    return
  }
  for d in derives {
    if not (d == "Add" or d == "Sub" or d == "Mul" or d == "Div" or d == "Mod") {
      diag.add(
        errorDiagnostic(
          "T0159",
          "'" + typeName + "' cannot derive " + d +
            ": a field holds an array, which derived code would treat by reference; write the method by hand (`==` compares arrays element by element)",
          span
        )
      )
    }
  }
}

func recordFieldTypeExprs(decl: in RecordDecl): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  for m in decl.members {
    match m {
      case RMField(fd) -> tys.add(fd.ty)
      case _ -> ()
    }
  }
  tys
}

// A record method sees the record's value generic parameters as `Int`
// constants, and its length checks wait for each instance, as in a
// value-generic function (D169).  The method is checked as if it declared
// them itself.
func withOwnerValueGenerics(fn: in FunctionDecl, ownerGenerics: in Option[GenericParams]): FunctionDecl {
  val owner = match ownerGenerics { case Some(g) -> g.params; case None -> newList() }
  val params: List[GenericParam] = newList()
  for p in owner {
    match p {
      case GPValue(_, _, _) -> params.add(p)
      case GPType(_, _) -> ()
    }
  }
  if params.count == 0 {
    return fn
  }
  match fn.generics {
    case Some(g) -> {
      for p in g.params {
        params.add(p)
      }
      fn.copy(generics = Some(value = g.copy(params = params)))
    }
    case None -> fn.copy(
      generics = Some(value = GenericParams(params = params, span = fn.span, legacyPrefixForm = false))
    )
  }
}

func opaqueFieldTypeExprs(decl: in OpaqueTypeDecl): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  for m in decl.members {
    match m {
      case OMField(fd) -> tys.add(fd.ty)
      case _ -> ()
    }
  }
  tys
}

func unionFieldTypeExprs(decl: in UnionDecl): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  for c in decl.cases {
    for f in c.fields {
      match f {
        case UFNamed(_, ty, _) -> tys.add(ty)
        case UFPos(ty, _) -> tys.add(ty)
      }
    }
  }
  tys
}

// Why `decl` is not a homogeneous numeric record, or `None` when it is.
func homogeneousNumericProblem(decl: in RecordDecl): Option[String] {
  match decl.generics {
    case Some(_) -> return Some(value = "a generic record has no single field type to add")
    case None -> ()
  }
  var fieldType = ""
  var count = 0
  for m in decl.members {
    match m {
      case RMField(fd) -> {
        val tn = match fd.ty.kind {
          case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
          case _ -> ""
        }
        if not isNumericPrimitiveName(tn) {
          return Some(
            value = "field '" + fd.name +
              "' is not a numeric primitive (component-wise arithmetic needs every field to be one numeric type)"
          )
        }
        if count > 0 and tn != fieldType {
          return Some(
            value = "field '" + fd.name + "' is " + tn + " but earlier fields are " + fieldType +
              " (every field must have the same numeric type)"
          )
        }
        fieldType = tn
        count = count + 1
      }
      case RMInvariant(_) -> return Some(
        value = "a record with an invariant cannot derive arithmetic (the component-wise result would not be re-checked)"
      )
      case RMFunc(_) -> ()
    }
  }
  if count == 0 {
    return Some(value = "it has no fields")
  }
  None
}

func checkUnionDeclTypes(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in UnionDecl): Unit {
  val ctx = declGenericContext(decl.generics)
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    var j = 0
    while j < c.fields.count {
      match c.fields[j] {
        case UFNamed(_, ty, _) -> {
          val _ = resolveType(tbl, ctx, diag, ty)
        }
        case UFPos(ty, _) -> {
          val _ = resolveType(tbl, ctx, diag, ty)
        }
      }
      j = j + 1
    }
    i = i + 1
  }
}

// #6445: a default method's (`IMFunc`) `Self` is the interface itself, and
// an interface never owns fields.  Both backends additionally lower a
// body-bearing interface member onto the interface's OWN class so
// interface-typed dispatch works (JVM `lowerImplMethod` on `ifClassName`,
// D-progress-676; MSIL's `lowerImplMethodMsil` DIM reuse, D-progress-753's
// caveat) — narrowing `Self` there to the interface, which has no fields to
// resolve.  Before this check, a default body's statements were never
// type-checked at all (`checkInterfaceDeclTypes` validated only the member
// SIGNATURE's type references), so `self.<name>` for a name that isn't an
// interface member panicked on JVM (J009) and silently mis-lowered on MSIL
// (the pre-existing `case None -> { MPop; MObject }` fallback). This is a
// purely NAME-based structural check — the checker already knows the
// interface's complete member list, so no type resolution is needed: reject
// any `<selfLike>.<name>` where `<selfLike>` is the `self` keyword OR
// another parameter explicitly typed `Self` (e.g. `other: in Self` — the
// same DIM-lowering gap applies to it, not just the literal receiver) and
// `<name>` doesn't match an interface member, leaving
// `self.<memberName>()` / bare `<memberName>()` calls to another interface
// member fully legal (the whole point of a default method).
//
// #6452 closed three boundaries of the name-based design (all still purely
// name/signature-based — no type inference):
//
//   1. A chained access through a `Self`-RETURNING member (`self.withX().base`,
//      `withX(self: in Self): Self` itself an interface member) hits the same
//      DIM gap but escaped the original walk (the `.base` receiver is a call,
//      not a bare `self`/param reference).  `isSelfLikeExpr` now also treats
//      `ECall(EMember(selfLike, m), _)` and bare `ECall(EPath([m]), _)` as
//      self-like when `m` is an interface member whose DECLARED return type is
//      `TSelf` (`ctx.selfReturningMembers`, from `interfaceMemberReturnsSelfNames`)
//      — recursively, so chains of arbitrary depth resolve.
//   2. A nested block that SHADOWS a `Self`-typed parameter name with an
//      unrelated local was spuriously rejected — the walk had no scope
//      awareness.  `DefaultBodyCtx.shadowed` is a shared, MUTABLE `List[String]`
//      acting as a stack: every scope-introducing construct (block entry,
//      `val`/`var`/`let`, match-arm pattern, `for`/lambda/catch binding) pushes
//      its bound names on entry and truncates back to the depth recorded on
//      entry when the scope exits (Lyric block scoping is block-scoped, not
//      function-scoped — see `block_shadow_self_test.l`).  `isSelfLikeExpr`
//      only treats a `Self`-typed param name as self-like while it is NOT in
//      `ctx.shadowed`.  The literal `self` receiver is immune — it is
//      recognised via the dedicated `ESelf` AST node regardless of any local
//      named `self` shadowing it in source (illegal — `self` cannot be rebound).
//   3. `isSelfLikeExpr` now unwraps `EParen`, so a parenthesized self-typed
//      reference (`(other).base`) is caught exactly like the bare form.
func interfaceMemberNames(decl: in InterfaceDecl): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMSig(sig) -> names.add(sig.name)
      case IMFunc(fn) -> names.add(fn.name)
      case IMAssoc(_) -> {
      }
    }
    i = i + 1
  }
  names
}

// Names of every interface member (signature or default-bodied) whose
// DECLARED return type is `TSelf` — used to recognise a chained
// `self.<m>().<field>` where `<m>` returns `Self` as itself self-like (#6452
// boundary 1).  Purely signature-based: the interface's own member list is
// fully local to the declaration, so no type inference is needed.
func interfaceMemberReturnsSelfNames(decl: in InterfaceDecl): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMSig(sig) -> if typeExprOptIsSelf(sig.ret) { names.add(sig.name) }
      case IMFunc(fn) -> if typeExprOptIsSelf(fn.ret) { names.add(fn.name) }
      case IMAssoc(_) -> {
      }
    }
    i = i + 1
  }
  names
}

func typeExprOptIsSelf(retOpt: in Option[TypeExpr]): Bool {
  match retOpt {
    case None -> false
    case Some(t) -> match t.kind { case TSelf -> true; case _ -> false }
  }
}

// Every bound name in `p`, appended to `acc` — used to push a pattern's
// bindings onto the shadow stack (match-arm patterns, `for`-loop bindings).
// Mirrors `Lyric.AliasRewriter.collectPatternLocalNames`'s traversal shape.
func addPatternShadowNames(acc: in List[String], p: in Pattern): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      acc.add(name)
      match inner {
        case Some(p2) -> addPatternShadowNames(acc, p2)
        case None -> {
        }
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        addPatternShadowNames(acc, args[i])
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, pattern, _) -> addPatternShadowNames(acc, pattern)
          case RPFShort(name, _) -> acc.add(name)
        }
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      var i = 0
      while i < patterns.count {
        addPatternShadowNames(acc, patterns[i])
        i = i + 1
      }
    }
    case PParen(inner) -> addPatternShadowNames(acc, inner)
    case PTypeTest(inner, _) -> addPatternShadowNames(acc, inner)
    case POr(patterns) -> {
      var i = 0
      while i < patterns.count {
        addPatternShadowNames(acc, patterns[i])
        i = i + 1
      }
    }
    case PWildcard -> {
    }
    case PLiteral(_) -> {
    }
    case PRange(_, _, _, _) -> {
    }
    case PConstRef(_) -> {
    }
    case PError -> {
    }
  }
}

// Truncates `shadowed` back to `depth` entries — pops every name pushed
// since the caller recorded `depth` on scope entry.
func truncateShadowed(shadowed: in List[String], depth: in Int): Unit {
  while shadowed.count > depth {
    shadowed.removeAt(shadowed.count - 1)
  }
}

// Names of every parameter (other than the `self` receiver, which is
// recognised via the dedicated `ESelf` AST node regardless of spelling)
// explicitly typed `Self` — e.g. `other: in Self`.
func selfTypedParamNames(fn: in FunctionDecl): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    if p.name != "self" {
      match p.ty.kind {
        case TSelf -> names.add(p.name)
        case _ -> {
        }
      }
    }
    i = i + 1
  }
  names
}

// Bundles the context threaded through the recursive walk below.  Mostly
// read-only (`ifaceName`/`memberNames`/`selfNames`/`selfReturningMembers`
// are fixed per default-method body), but `shadowed` is a shared MUTABLE
// `List[String]` the walk pushes onto and truncates as it descends into
// nested scopes (#6452 boundary 2) — the ctx record itself is still passed
// around immutably (a fresh copy of the record would share the same `List`
// reference, since `List` is itself a mutable reference type).
pub record DefaultBodyCtx {
  ifaceName: String
  memberNames: List[String]
  selfNames: List[String]
  selfReturningMembers: List[String]
  shadowed: List[String]
}

// True when `e` denotes a value statically typed `Self` inside a default
// method body: the `self` keyword itself; a bare reference to another
// `Self`-typed parameter NOT currently shadowed by a nested local
// (`ctx.shadowed`, #6452 boundary 2); a parenthesized self-like expression
// (`(other)`, #6452 boundary 3); or a call to an interface member whose
// declared return type is `Self`, on a self-like receiver or bare
// (`self.withX()` / bare `withX()`, #6452 boundary 1) — recursive, so
// chains of arbitrary depth (`self.withX().withX()`) resolve.
func isSelfLikeExpr(e: in Expr, ctx: in DefaultBodyCtx): Bool {
  match e.kind {
    case ESelf -> true
    case EParen(inner) -> isSelfLikeExpr(inner, ctx)
    case EPath(path) -> path.segments.count == 1 and listContains(ctx.selfNames, path.segments[0]) and
      not listContains(ctx.shadowed, path.segments[0])
    case ECall(f, _) -> match f.kind {
      case EMember(recv, m) -> isSelfLikeExpr(recv, ctx) and
        listContains(ctx.selfReturningMembers, m)
      case EPath(path) -> path.segments.count == 1 and
        listContains(ctx.selfReturningMembers, path.segments[0])
      case _ -> false
    }
    case _ -> false
  }
}

func checkDefaultBodySelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, fn: in FunctionDecl): Unit {
  match fn.body {
    case None -> {
    }
    case Some(body) -> match body {
      case FBExpr(e) -> checkExprSelfMembers(diag, ctx, e)
      case FBBlock(b) -> checkBlockSelfMembers(diag, ctx, b)
    }
  }
}

func checkExprSelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, e: in Expr): Unit {
  match e.kind {
    case EMember(recv, name) -> {
      if isSelfLikeExpr(recv, ctx) {
        if not listContains(ctx.memberNames, name) {
          diag.add(
            errorDiagnostic(
              "T0118",
              "'" + name + "' is not a member of interface '" + ctx.ifaceName +
                "': a default method body may only reference interface members through a Self-typed value; field access requires overriding the method in an impl",
              e.span
            )
          )
        }
      }
      checkExprSelfMembers(diag, ctx, recv)
    }
    case ELiteral(_) -> {
    }
    case EPath(_) -> {
    }
    case ESelf -> {
    }
    case EResult -> {
    }
    case EError -> {
    }
    case EParen(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case EAwait(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case EYield(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case ESpawn(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case EOld(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case EPropagate(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case ETry(inner) -> checkExprSelfMembers(diag, ctx, inner)
    case EPrefix(_, inner) -> checkExprSelfMembers(diag, ctx, inner)
    case ETuple(elems) -> checkExprListSelfMembers(diag, ctx, elems)
    case EList(elems) -> checkExprListSelfMembers(diag, ctx, elems)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> checkExprSelfMembers(diag, ctx, se)
          case ISText(_) -> {
          }
        }
        i = i + 1
      }
    }
    case EBinop(_, l, r) -> {
      checkExprSelfMembers(diag, ctx, l)
      checkExprSelfMembers(diag, ctx, r)
    }
    case EAssign(t, _, v) -> {
      checkExprSelfMembers(diag, ctx, t)
      checkExprSelfMembers(diag, ctx, v)
    }
    case ETypeApp(f, _) -> checkExprSelfMembers(diag, ctx, f)
    case EIndex(recv, idxs) -> {
      checkExprSelfMembers(diag, ctx, recv)
      checkExprListSelfMembers(diag, ctx, idxs)
    }
    case ECall(f, args) -> {
      checkExprSelfMembers(diag, ctx, f)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> checkExprSelfMembers(diag, ctx, v)
          case CANamed(_, v, _) -> checkExprSelfMembers(diag, ctx, v)
        }
        i = i + 1
      }
    }
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> {
        checkExprSelfMembers(diag, ctx, a)
        checkExprSelfMembers(diag, ctx, b)
      }
      case RBHalfOpen(a, b, _) -> {
        checkExprSelfMembers(diag, ctx, a)
        checkExprSelfMembers(diag, ctx, b)
      }
      case RBLowerOpen(a) -> checkExprSelfMembers(diag, ctx, a)
      case RBUpperOpen(a) -> checkExprSelfMembers(diag, ctx, a)
    }
    case EIf(c, t, eOpt, _) -> {
      checkExprSelfMembers(diag, ctx, c)
      checkExprOrBlockSelfMembers(diag, ctx, t)
      match eOpt {
        case None -> {
        }
        case Some(b) -> checkExprOrBlockSelfMembers(diag, ctx, b)
      }
    }
    case EMatch(subj, arms) -> {
      checkExprSelfMembers(diag, ctx, subj)
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        // Each arm's pattern bindings shadow for the guard and body only —
        // sibling arms don't see each other's bindings (#6452 boundary 2).
        val armDepth = ctx.shadowed.count
        addPatternShadowNames(ctx.shadowed, arm.pattern)
        match arm.guard {
          case None -> {
          }
          case Some(g) -> checkExprSelfMembers(diag, ctx, g)
        }
        checkExprOrBlockSelfMembers(diag, ctx, arm.body)
        truncateShadowed(ctx.shadowed, armDepth)
        i = i + 1
      }
    }
    case EBlock(blk) -> checkBlockSelfMembers(diag, ctx, blk)
    case EUnsafe(blk) -> checkBlockSelfMembers(diag, ctx, blk)
    case EForall(_, w, body, _) -> {
      match w {
        case None -> {
        }
        case Some(we) -> checkExprSelfMembers(diag, ctx, we)
      }
      checkExprSelfMembers(diag, ctx, body)
    }
    case EExists(_, w, body, _) -> {
      match w {
        case None -> {
        }
        case Some(we) -> checkExprSelfMembers(diag, ctx, we)
      }
      checkExprSelfMembers(diag, ctx, body)
    }
    // A nested lambda still captures the enclosing default method's `self`,
    // so a `self.<name>` inside it is the exact same problem — unlike the
    // yield-tracking `exprContainsYield` (whose "yield" scoping rules
    // differ per lambda), descend into the lambda body here.  Lambda
    // parameters shadow like any other binding (#6452 boundary 2).
    case ELambda(lambdaParams, body) -> {
      val lambdaDepth = ctx.shadowed.count
      var i = 0
      while i < lambdaParams.count {
        ctx.shadowed.add(lambdaParams[i].name)
        i = i + 1
      }
      checkBlockSelfMembers(diag, ctx, body)
      truncateShadowed(ctx.shadowed, lambdaDepth)
    }
  }
}

func checkExprListSelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, es: in List[Expr]): Unit {
  var i = 0
  while i < es.count {
    checkExprSelfMembers(diag, ctx, es[i])
    i = i + 1
  }
}

func checkExprOrBlockSelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, eob: in ExprOrBlock): Unit {
  match eob {
    case EOBExpr(e) -> checkExprSelfMembers(diag, ctx, e)
    case EOBBlock(b) -> checkBlockSelfMembers(diag, ctx, b)
  }
}

// Lyric block scoping is BLOCK-scoped, not function-scoped (see
// `block_shadow_self_test.l`): every `val`/`var`/`let` a nested block binds
// stops shadowing once that block exits, even though (2) already lets a
// nested block push MORE names during its own statements — this function's
// own recorded depth only ever needs to truncate back to what it was on
// entry, since every callee already restores its own additions before
// returning (#6452 boundary 2).
func checkBlockSelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, blk: in Block): Unit {
  val blockDepth = ctx.shadowed.count
  var i = 0
  while i < blk.statements.count {
    checkStmtSelfMembers(diag, ctx, blk.statements[i])
    i = i + 1
  }
  truncateShadowed(ctx.shadowed, blockDepth)
}

func checkStmtSelfMembers(diag: in List[Diagnostic], ctx: in DefaultBodyCtx, stmt: in Statement): Unit {
  match stmt.kind {
    case SExpr(e) -> checkExprSelfMembers(diag, ctx, e)
    case SThrow(e) -> checkExprSelfMembers(diag, ctx, e)
    case SReturn(None) -> {
    }
    case SReturn(Some(e)) -> checkExprSelfMembers(diag, ctx, e)
    case SBreak(_) -> {
    }
    case SContinue(_) -> {
    }
    case SInvariant(e) -> checkExprSelfMembers(diag, ctx, e)
    case SItem(_) -> {
    }
    case SAssign(t, _, v) -> {
      checkExprSelfMembers(diag, ctx, t)
      checkExprSelfMembers(diag, ctx, v)
    }
    // The initializer is checked BEFORE the new name shadows (it can still
    // legitimately reference the outer name), then the bound name(s) are
    // pushed for the rest of the enclosing block (#6452 boundary 2) — popped
    // by the enclosing `checkBlockSelfMembers`'s own truncation on exit.
    case SLocal(binding) -> match binding {
      case LBVal(pat, _, e) -> {
        checkExprSelfMembers(diag, ctx, e)
        addPatternShadowNames(ctx.shadowed, pat)
      }
      case LBLet(name, _, e) -> {
        checkExprSelfMembers(diag, ctx, e)
        ctx.shadowed.add(name)
      }
      case LBVar(name, _, Some(e)) -> {
        checkExprSelfMembers(diag, ctx, e)
        ctx.shadowed.add(name)
      }
      case LBVar(name, _, None) -> ctx.shadowed.add(name)
    }
    case STry(body, catches, finally_) -> {
      checkBlockSelfMembers(diag, ctx, body)
      var i = 0
      while i < catches.count {
        // A catch binding shadows for its own handler block only.
        val catchDepth = ctx.shadowed.count
        match catches[i].bindName {
          case Some(n) -> ctx.shadowed.add(n)
          case None -> {
          }
        }
        checkBlockSelfMembers(diag, ctx, catches[i].body)
        truncateShadowed(ctx.shadowed, catchDepth)
        i = i + 1
      }
      match finally_ {
        case None -> {
        }
        case Some(fb) -> checkBlockSelfMembers(diag, ctx, fb)
      }
    }
    case SDefer(b) -> checkBlockSelfMembers(diag, ctx, b)
    case SScope(_, b) -> checkBlockSelfMembers(diag, ctx, b)
    case SLoop(_, b) -> checkBlockSelfMembers(diag, ctx, b)
    case SFor(_, pat, iter, body) -> {
      // The iterable is evaluated in the OUTER scope, before the loop
      // binding exists; the pattern's names shadow for the loop body only.
      checkExprSelfMembers(diag, ctx, iter)
      val forDepth = ctx.shadowed.count
      addPatternShadowNames(ctx.shadowed, pat)
      checkBlockSelfMembers(diag, ctx, body)
      truncateShadowed(ctx.shadowed, forDepth)
    }
    case SWhile(_, cond, body) -> {
      checkExprSelfMembers(diag, ctx, cond)
      checkBlockSelfMembers(diag, ctx, body)
    }
    case SRule(l, r) -> {
      checkExprSelfMembers(diag, ctx, l)
      checkExprSelfMembers(diag, ctx, r)
    }
  }
}

func checkInterfaceDeclTypes(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in InterfaceDecl): Unit {
  val memberNames = interfaceMemberNames(decl)
  val selfReturningMembers = interfaceMemberReturnsSelfNames(decl)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMSig(sig) -> checkMemberSigTypes(tbl, diag, decl.generics, sig.generics, sig.params, sig.ret)
      case IMFunc(fn) -> {
        checkMemberSigTypes(tbl, diag, decl.generics, fn.generics, fn.params, fn.ret)
        val shadowed: List[String] = newList()
        val ctx = DefaultBodyCtx(
          ifaceName = decl.name,
          memberNames = memberNames,
          selfNames = selfTypedParamNames(fn),
          selfReturningMembers = selfReturningMembers,
          shadowed = shadowed
        )
        checkDefaultBodySelfMembers(diag, ctx, fn)
      }
      case IMAssoc(_) -> {
      }
    }
    i = i + 1
  }
}

// An interface method's `requires:`/`ensures:` clauses are checked as `Bool`
// in the method's parameter scope, `result` being the declared return type
// (#8331).  An implementing method inherits the clauses after type checking,
// so a clause is reported once, here, at the interface.
func checkInterfaceContracts(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in InterfaceDecl,
): Unit {
  val ifaceGen = extractGenericNames(decl.generics)
  for m in decl.members {
    match m {
      case IMSig(sig) -> checkMethodContracts(
        tbl,
        sigs,
        diag,
        ifaceGen,
        sig.generics,
        sig.params,
        sig.ret,
        sig.isAsync,
        sig.contracts,
        sig.span
      )
      case IMFunc(fn) -> checkMethodContracts(
        tbl,
        sigs,
        diag,
        ifaceGen,
        fn.generics,
        fn.params,
        fn.ret,
        fn.isAsync,
        fn.contracts,
        fn.span
      )
      case IMAssoc(_) -> ()
    }
  }
}

func checkMethodContracts(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  ownerGenerics: in List[String],
  ownGenerics: in Option[GenericParams],
  params: in List[Param],
  ret: in Option[TypeExpr],
  isAsync: in Bool,
  contracts: in List[ContractClause],
  span: in Span,
): Unit {
  if contracts.count == 0 {
    return
  }
  val rsig = resolveMethodSigParts(tbl, "", ownerGenerics, ownGenerics, params, ret, isAsync, false, false, false, span)
  val combined: List[String] = newList()
  for g in ownerGenerics {
    combined.add(g)
  }
  for g in extractGenericNames(ownGenerics) {
    combined.add(g)
  }
  val noFields: Map[String, Type] = newMap()
  val sc = newScopeForFunction(rsig.returnTy, combined, ret, noFields, false, TyError)
  for p in rsig.params {
    val isMut = match p.mode { case PMIn -> false; case _ -> true }
    scopeAdd(sc, LocalBinding(name = p.name, ty = p.ty, isMutable = isMut, byRefParam = isMut))
  }
  checkContractClauses(sc, tbl, sigs, diag, contracts)
}

func checkOpaqueDeclTypes(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in OpaqueTypeDecl): Unit {
  val ctx = declGenericContext(decl.generics)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case OMField(field) -> {
        val _ = resolveType(tbl, ctx, diag, field.ty)
      }
      case OMInvariant(_) -> {
      }
    }
    i = i + 1
  }
}

// A protected type's value generic parameter makes the declaration specialised
// per length, whole and in the package that uses it (#8149), so for now the
// type is not shared across packages: T0168 on a `pub` one.
func checkProtectedValueGenericVisibility(
  diag: in List[Diagnostic],
  decl: in ProtectedTypeDecl,
  vis: in Option[Visibility],
): Unit {
  if valueGenericNames(decl.generics).count == 0 {
    return
  }
  match vis {
    case Some(VisPub(_)) -> diag.add(
      errorDiagnostic(
        "T0168",
        "the protected type '" + decl.name +
          "' has a value generic parameter, so each length is specialised in the package that uses it and the type cannot be pub yet (#8149)",
        decl.span
      )
    )
    case _ -> ()
  }
}

func checkProtectedDeclTypes(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in ProtectedTypeDecl): Unit {
  val ctx = declGenericContext(decl.generics)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(field) -> {
        match field {
          case PFVar(_, ty, _, _, _, _) -> {
            val _ = resolveType(tbl, ctx, diag, ty)
          }
          case PFLet(_, ty, _, _, _, _) -> {
            val _ = resolveType(tbl, ctx, diag, ty)
          }
          case PFImmutable(fd) -> {
            val _ = resolveType(tbl, ctx, diag, fd.ty)
          }
        }
      }
      case PMEntry(entryDecl) -> {
        var j = 0
        while j < entryDecl.params.count {
          val _ = resolveType(tbl, ctx, diag, entryDecl.params[j].ty)
          j = j + 1
        }
        match entryDecl.ret {
          case Some(te) -> {
            val _ = resolveType(tbl, ctx, diag, te)
          }
          case None -> {
          }
        }
      }
      case PMFunc(fn) -> {
        checkMemberSigTypes(tbl, diag, decl.generics, fn.generics, fn.params, fn.ret)
        checkProtectedFuncShape(diag, decl.name, fn)
      }
      case PMInvariant(_) -> {
      }
    }
    i = i + 1
  }
}

// A protected `func` runs under the instance lock like an `entry` (§7.5,
// #7363), so it cannot be `async` (a monitor cannot be held across a
// suspension, and the CLR `Monitor` is owned by the thread that took it) and
// cannot declare its own type parameters (neither backend can lock a
// method-generic member). T0135 (#7384).
func checkProtectedFuncShape(diag: in List[Diagnostic], typeName: in String, fn: in FunctionDecl): Unit {
  if fn.isAsync {
    diag.add(
      errorDiagnostic(
        "T0135",
        "protected type '" + typeName + "': func '" + fn.name + "' cannot be async; its body runs under the instance lock",
        fn.span
      )
    )
  }
  match fn.generics {
    case Some(_) -> diag.add(
      errorDiagnostic(
        "T0135",
        "protected type '" + typeName + "': func '" + fn.name +
          "' cannot declare its own type parameters; its body runs under the instance lock",
        fn.span
      )
    )
    case None -> ()
  }
}

// #6481: the protected type's own field names, resolved to `LocalBinding`s so
// an entry/func body's bare-name field references (`count = count + 1`,
// `items.add(v)` — there is no explicit `self` receiver, unlike a record
// method) resolve during body type-checking. `var` fields are mutable;
// `let`/plain fields are not — reusing `LocalBinding.isMutable` gets the
// existing T0087 "cannot reassign immutable" check for free on a bare-name
// write to a `let` field, with no new mode-checker rule required. Diagnostics
// from re-resolving each field's type go to a scratch list: `checkProtectedDeclTypes`
// (T4) already reports declaration-position errors for these same type refs.
func protectedFieldLocals(tbl: in SymbolTable, ctx: in GenericContext, decl: in ProtectedTypeDecl): List[LocalBinding] {
  val scratch: List[Diagnostic] = newList()
  val locals: List[LocalBinding] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(field) -> {
        match field {
          case PFVar(name, ty, _, _, _, _) -> {
            locals.add(LocalBinding(name = name, ty = resolveType(tbl, ctx, scratch, ty), isMutable = true))
          }
          case PFLet(name, ty, _, _, _, _) -> {
            locals.add(LocalBinding(name = name, ty = resolveType(tbl, ctx, scratch, ty), isMutable = false))
          }
          case PFImmutable(fd) -> {
            locals.add(LocalBinding(name = fd.name, ty = resolveType(tbl, ctx, scratch, fd.ty), isMutable = fd.isMutable))
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  locals
}

// #6481: `checkProtectedDeclTypes` (T4, above) only resolves an entry/func
// member's param/return TYPE REFERENCES — the body itself was never type-
// checked, so an ill-typed body (mismatched returns, unknown names, bad
// arguments) compiled silently and reached the backends as a codegen panic
// or miscompile. Routes every member through the ordinary `checkFunctionBody`
// machinery, seeded with the protected fields (`protectedFieldLocals`) so
// bare-name field access resolves.
//
// `PMFunc` wraps a real `FunctionDecl`, so it is passed straight through.
// `PMEntry` wraps the distinct `EntryDecl` AST shape (no `isAsync`/
// `generics`/`whereClause` — the parser never accepts `async entry` or
// `entry foo[T](...)`, so an entry body is always synchronous and never
// separately generic), so it is lifted into a synthetic `FunctionDecl` first.
// `resolveMethodSigParts` (§7a) already builds the right owner-generics-aware
// `ResolvedSignature` for a member with no `self` param (protected members
// never have one, so its `self`-drop is a no-op here) — reused as-is, with
// `sig.generics` widened to include the OWNER's generic names too (not just
// the member's own) so a local `val x: T = …` inside the body of a generic
// protected type's member resolves `T` the same way a local inside the
// declaring type's other members would.
// The protected-type analog of `recordSelfType`: the concrete receiver type
// member bodies see for whole-`self` reads and the ECall bare-sibling
// fallback (#6483).  Same raw-`TyVar` type-argument convention as
// `recordSelfType` (see its doc comment).
func protectedSelfType(tbl: in SymbolTable, decl: in ProtectedTypeDecl, ownerGenerics: in List[String]): Type {
  match symTableTryFindOne(tbl, decl.name) {
    case Some(sym) -> match symbolTypeIdOpt(sym) {
      case Some(tid) -> {
        val targs: List[Type] = newList()
        var i = 0
        while i < ownerGenerics.count {
          targs.add(TyVar(name = ownerGenerics[i]))
          i = i + 1
        }
        TyUser(id = tid, name = decl.name, args = targs)
      }
      case None -> TyError
    }
    case None -> TyError
  }
}

func checkProtectedMemberBodies(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in ProtectedTypeDecl,
): Unit {
  val ownerGenerics = extractGenericNames(decl.generics)
  val ctx = declGenericContext(decl.generics)
  val fieldLocals = protectedFieldLocals(tbl, ctx, decl)
  val selfTy = protectedSelfType(tbl, decl, ownerGenerics)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMEntry(entryDecl) -> {
        val noGenerics: Option[GenericParams] = None
        val sig0 = resolveMethodSigParts(
          tbl,
          "",
          ownerGenerics,
          noGenerics,
          entryDecl.params,
          entryDecl.ret,
          false,
          false,
          false,
          true,
          entryDecl.span
        )
        val sig = ResolvedSignature(
          generics = ownerGenerics,
          bounds = sig0.bounds,
          params = sig0.params,
          returnTy = sig0.returnTy,
          isAsync = sig0.isAsync,
          isHot = sig0.isHot,
          isGenerator = sig0.isGenerator,
          originPackage = sig0.originPackage,
          span = sig0.span,
          isPure = false,
          isIo = sig0.isIo,
          isEntry = sig0.isEntry,
          isExternFunc = sig0.isExternFunc
        )
        val syntheticBody: Option[FunctionBody] = if entryDecl.hasBody { Some(value = entryDecl.body) } else { None }
        val fn = FunctionDecl(
          docComments = entryDecl.docComments,
          annotations = entryDecl.annotations,
          visibility = entryDecl.visibility,
          isAsync = false,
          name = entryDecl.name,
          generics = None,
          params = entryDecl.params,
          ret = entryDecl.ret,
          whereClause = None,
          contracts = entryDecl.contracts,
          body = syntheticBody,
          span = entryDecl.span
        )
        checkFunctionBody(
          tbl,
          sigs,
          diag,
          withOwnerValueGenerics(fn, decl.generics),
          sig,
          fieldLocals,
          fieldLocals,
          true,
          selfTy
        )
      }
      case PMFunc(fn) -> {
        val ownFnGenerics = extractGenericNames(fn.generics)
        val combinedGenerics: List[String] = newList()
        var g = 0
        while g < ownerGenerics.count {
          combinedGenerics.add(ownerGenerics[g])
          g = g + 1
        }
        var g2 = 0
        while g2 < ownFnGenerics.count {
          combinedGenerics.add(ownFnGenerics[g2])
          g2 = g2 + 1
        }
        val sig0 = resolveMethodSigParts(
          tbl,
          "",
          ownerGenerics,
          fn.generics,
          fn.params,
          fn.ret,
          fn.isAsync,
          fnHasAnnotation(fn, "pure"),
          fnHasAnnotation(fn, "io"),
          false,
          fn.span
        )
        val sig = ResolvedSignature(
          generics = combinedGenerics,
          bounds = sig0.bounds,
          params = sig0.params,
          returnTy = sig0.returnTy,
          isAsync = sig0.isAsync,
          isHot = sig0.isHot,
          isGenerator = sig0.isGenerator,
          originPackage = sig0.originPackage,
          span = sig0.span,
          isPure = fnHasAnnotation(fn, "pure"),
          isIo = sig0.isIo,
          isEntry = sig0.isEntry,
          isExternFunc = sig0.isExternFunc
        )
        checkFunctionBody(
          tbl,
          sigs,
          diag,
          withOwnerValueGenerics(fn, decl.generics),
          sig,
          fieldLocals,
          fieldLocals,
          true,
          selfTy
        )
      }
      case PMInvariant(inv) -> {
        // The invariant sees the type's value generic parameters as `Int`
        // constants, like a member body does.
        val invLocals: List[LocalBinding] = newList()
        for fl in fieldLocals {
          invLocals.add(fl)
        }
        for vp in valueGenericNames(decl.generics) {
          invLocals.add(LocalBinding(name = vp, ty = TyPrim(pt = PtInt), isMutable = false))
        }
        checkProtectedInvariant(tbl, sigs, diag, inv, ownerGenerics, invLocals, selfTy)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// A protected type's `invariant:` clause is a `Bool` over its fields, which
// it reads by bare name as an entry body does.  It is checked here so an
// ill-typed clause is reported and its literals follow the expected-type
// rules (D155): the contract elaborator copies the clause into every entry's
// exit checks after type checking (#7988).
func checkProtectedInvariant(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  inv: in InvariantClause,
  ownerGenerics: in List[String],
  fieldLocals: in List[LocalBinding],
  selfTy: in Type,
): Unit {
  checkInvariantExpr(tbl, sigs, diag, inv.expr, inv.span, ownerGenerics, fieldLocals, selfTy)
}

// An `invariant:` expression, checked as `Bool` with the type's fields bound
// by bare name.
func checkInvariantExpr(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  expr: in Expr,
  sp: in Span,
  ownerGenerics: in List[String],
  fieldLocals: in List[LocalBinding],
  selfTy: in Type,
): Unit {
  val selfFields: Map[String, Type] = newMap()
  for f in fieldLocals {
    selfFields.add(f.name, f.ty)
  }
  val noRet: Option[TypeExpr] = None
  val sc = newScopeForFunction(TyPrim(pt = PtBool), ownerGenerics, noRet, selfFields, true, selfTy)
  for f in fieldLocals {
    scopeAdd(sc, f)
  }
  checkBoolClause(sc, tbl, sigs, diag, expr, "invariant", sp)
}

// A record's or opaque type's `invariant:` is type-checked through the
// construction checker `synthesizeInvariantCheckers` adds, which asserts
// only its `and`-conjuncts without a quantifier: one with a quantifier
// cannot be evaluated at runtime (W0002) and is `lyric prove`'s alone.
// Those conjuncts are checked here, at the clause (#8322).
func checkQuantifiedInvariantConjuncts(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  inv: in InvariantClause,
  ownerGenerics: in List[String],
  fieldLocals: in List[LocalBinding],
  selfTy: in Type,
): Unit {
  val parts: List[Expr] = newList()
  collectInvariantConjuncts(inv.expr, parts)
  for part in parts {
    if exprHasQuantifier(part) {
      checkInvariantExpr(tbl, sigs, diag, part, part.span, ownerGenerics, fieldLocals, selfTy)
    }
  }
}

// The top-level `and`-conjuncts of `e`, through parentheses, split as the
// contract elaborator splits a clause it checks at runtime.
func collectInvariantConjuncts(e: in Expr, acc: in List[Expr]): Unit {
  match e.kind {
    case EBinop(op, l, r) -> match op {
      case BAnd -> {
        collectInvariantConjuncts(l, acc)
        collectInvariantConjuncts(r, acc)
      }
      case _ -> acc.add(e)
    }
    case EParen(inner) -> collectInvariantConjuncts(inner, acc)
    case _ -> acc.add(e)
  }
}

func opaqueFieldLocals(tbl: in SymbolTable, ctx: in GenericContext, decl: in OpaqueTypeDecl): List[LocalBinding] {
  val scratch: List[Diagnostic] = newList()
  val locals: List[LocalBinding] = newList()
  for m in decl.members {
    match m {
      case OMField(field) -> locals.add(
        LocalBinding(
          name = field.name,
          ty = resolveType(tbl, ctx, scratch, field.ty),
          isMutable = field.isMutable
        )
      )
      case OMInvariant(_) -> ()
    }
  }
  locals
}

// The quantified `invariant:` conjuncts of an opaque type (#8322).
func checkOpaqueInvariants(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in OpaqueTypeDecl,
): Unit {
  if not opaqueHasInvariant(decl) {
    return
  }
  val ownerGenerics = extractGenericNames(decl.generics)
  val fieldLocals = opaqueFieldLocals(tbl, declGenericContext(decl.generics), decl)
  val selfTy = opaqueSelfType(tbl, decl.name, ownerGenerics)
  for m in decl.members {
    match m {
      case OMInvariant(inv) -> checkQuantifiedInvariantConjuncts(tbl, sigs, diag, inv, ownerGenerics, fieldLocals, selfTy)
      case OMField(_) -> ()
    }
  }
}

func opaqueHasInvariant(decl: in OpaqueTypeDecl): Bool {
  for m in decl.members {
    match m {
      case OMInvariant(_) -> return true
      case OMField(_) -> ()
    }
  }
  false
}

func opaqueSelfType(tbl: in SymbolTable, name: in String, ownerGenerics: in List[String]): Type {
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> match symbolTypeIdOpt(sym) {
      case Some(tid) -> {
        val targs: List[Type] = newList()
        for g in ownerGenerics {
          targs.add(TyVar(name = g))
        }
        TyUser(id = tid, name = name, args = targs)
      }
      case None -> TyError
    }
    case None -> TyError
  }
}

// #6487: the record-body counterpart of `protectedFieldLocals` — resolves
// every `RMField`'s declared type against the record's OWN generic context
// (so a `Box[T]` field `v: T` stays `TyVar("T")`, matching `sig.generics`
// below rather than erasing to `TyError`) into `LocalBinding`s. Unlike
// `protectedFieldLocals`, this list is used ONLY to seed `sc.selfFields`
// (the `self.field` map) — record-body methods have no bare-name field
// spelling (D037 requires the explicit `self` receiver; codegen never
// desugars a bare identifier to `EMember(ESelf, name)` for `RMFunc`, only for
// protected `entry`/`func` members), so it must never also be threaded
// through `checkFunctionBody`'s bare-name `extraLocals` slot.
func recordFieldLocals(tbl: in SymbolTable, ctx: in GenericContext, decl: in RecordDecl): List[LocalBinding] {
  val scratch: List[Diagnostic] = newList()
  val locals: List[LocalBinding] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(field) -> {
        locals.add(
          LocalBinding(name = field.name, ty = resolveType(tbl, ctx, scratch, field.ty), isMutable = field.isMutable)
        )
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  locals
}

// #6487: `RMFunc` (record-body method) bodies were never routed through
// `checkFunctionBody` at all — not even the ordinary arg/return-type checks
// every plain function gets, let alone `self.field` resolution — so an
// ill-typed body (`func doubled(self: in Thing): Int { "oops" }`) compiled
// with zero diagnostics. `self`'s type annotation is irrelevant here (D037's
// `injectSelfIfNeeded` guarantees `fn.params[0]` is always named `self`,
// explicit or synthesized as `Self`; `resolveMethodSigParts` already drops
// it from `sig.params` on that name alone) — the receiver is always exactly
// this record, so `recordFieldLocals` seeds `self.field` regardless of what
// (if anything) the user wrote as `self`'s type.
// #6487 review: a record's own `Self` — the type used to substitute a
// literal `Self` return-type annotation (`func dup(): Self { … }`, the
// `docs/01` `Cloneable`-style shape) into the concrete record type before
// the T0070 return-type check runs. Without this, `resolveType` leaves an
// unsubstituted `Self` annotation as the `TySelf` placeholder, which
// `typeAssignable` never accepts from a concrete `TyUser` body value
// (`case _ -> false` for any non-`TyUser` expected type) — a false-positive
// T0070 on a body that was always well-typed (found via the #6417 case in
// `impl_method_self_test.l`'s battery run, same root cause as the impl-side
// fix below).
// The type-argument list is built with raw `TyVar(name = ...)` rather than
// the `ctx`/`gctxPush`-scoped resolution `recordFieldLocals` uses for the
// same generic names: this type only feeds `substitutesSelf` and
// equivalence checks, and `typeEquiv` treats every `TyVar` as universally
// equivalent, so the two representations never need to agree structurally
// (#6488 review nit).
func recordSelfType(tbl: in SymbolTable, decl: in RecordDecl, ownerGenerics: in List[String]): Type {
  match symTableTryFindOne(tbl, decl.name) {
    case Some(sym) -> match symbolTypeIdOpt(sym) {
      case Some(tid) -> {
        val targs: List[Type] = newList()
        var i = 0
        while i < ownerGenerics.count {
          targs.add(TyVar(name = ownerGenerics[i]))
          i = i + 1
        }
        TyUser(id = tid, name = decl.name, args = targs)
      }
      case None -> TyError
    }
    case None -> TyError
  }
}

// T0165 (#8179): a method's receiver is `in` or `inout`.  An `out`
// receiver would be a method called on a value that does not exist yet.  An
// interface method's receiver, and so an `impl` method's, is `in`: a call
// through an interface value passes that value, and has no place of the
// implementing type to assign.
func checkReceiverModes(diag: in List[Diagnostic], items: in List[Item]): Unit {
  for it in items {
    match it.kind {
      case IFunc(fd) -> {
        checkReceiverParams(diag, fd.params, fd.name, true)
        checkByRefParams(diag, fd.params, fd.name, fd.isAsync)
      }
      case IRecord(d) -> checkRecordReceivers(diag, d)
      case IExposedRec(d) -> checkRecordReceivers(diag, d)
      case IImpl(d) -> {
        for m in d.members {
          match m {
            case IMplFunc(fn) -> {
              checkReceiverParams(diag, fn.params, fn.name, false)
              checkByRefParams(diag, fn.params, fn.name, fn.isAsync)
            }
            case _ -> ()
          }
        }
      }
      case IProtected(d) -> {
        for m in d.members {
          match m {
            case PMEntry(ed) -> {
              checkProtectedReceiver(diag, ed.params, ed.name)
              checkByRefParams(diag, ed.params, ed.name, false)
            }
            case PMFunc(fn) -> {
              checkProtectedReceiver(diag, fn.params, fn.name)
              checkByRefParams(diag, fn.params, fn.name, fn.isAsync)
            }
            case _ -> ()
          }
        }
      }
      case IInterface(d) -> {
        for m in d.members {
          match m {
            case IMSig(sig) -> {
              checkReceiverParams(diag, sig.params, sig.name, false)
              checkByRefParams(diag, sig.params, sig.name, sig.isAsync)
            }
            case IMFunc(fn) -> {
              checkReceiverParams(diag, fn.params, fn.name, false)
              checkByRefParams(diag, fn.params, fn.name, fn.isAsync)
            }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
  }
}

func checkRecordReceivers(diag: in List[Diagnostic], d: in RecordDecl): Unit {
  for m in d.members {
    match m {
      case RMFunc(fn) -> {
        checkReceiverParams(diag, fn.params, fn.name, true)
        checkByRefParams(diag, fn.params, fn.name, fn.isAsync)
      }
      case _ -> ()
    }
  }
}

// T0182: an `out`/`inout` parameter refers to the caller's place, so it has
// no value to default.  T0183: an `async` function's `out`/`inout` parameter
// would have to stay a live reference to the caller's place across every
// suspension, which no target can keep; the function returns the new value
// instead.
func checkByRefParams(diag: in List[Diagnostic], params: in List[Param], name: in String, isAsync: in Bool): Unit {
  for p in params {
    val modeText = match p.mode { case PMOut -> "out"; case PMInout -> "inout"; case PMIn -> "" }
    if modeText.length > 0 {
      match p.dflt {
        case Some(d) -> diag.add(
          errorDiagnostic(
            "T0182",
            "parameter '" + p.name + "' of '" + name + "' is `" + modeText +
              "` and cannot have a default value: it refers to the caller's place, so every call must pass one",
            d.span
          )
        )
        case None -> ()
      }
      if isAsync {
        diag.add(
          errorDiagnostic(
            "T0183",
            "parameter '" + p.name + "' of async function '" + name + "' cannot be `" + modeText +
              "`: it would have to refer to the caller's place across every `await`; return the new value instead (a tuple for several), or pass a record and change its `var` fields",
            p.span
          )
        )
      }
    }
  }
}

// A protected type is shared by reference and never replaced: its entries
// and functions change its fields, under its lock, so a receiver declared
// `out` or `inout` is T0165.
func checkProtectedReceiver(diag: in List[Diagnostic], params: in List[Param], name: in String): Unit {
  if params.count == 0 or params[0].name != "self" {
    return
  }
  match params[0].mode {
    case PMIn -> ()
    case _ -> diag.add(
      errorDiagnostic(
        "T0165",
        "the receiver of protected-type member '" + name +
          "' cannot be `out` or `inout`: a protected object is shared and is never replaced; assign its `var` fields instead",
        params[0].span
      )
    )
  }
}

func checkReceiverParams(
  diag: in List[Diagnostic], params: in List[Param], name: in String, inoutAllowed: in Bool
): Unit {
  if params.count == 0 or params[0].name != "self" {
    return
  }
  match params[0].mode {
    case PMOut -> diag.add(
      errorDiagnostic(
        "T0165",
        "the receiver of '" + name +
          "' cannot be `out`: a method is called on an existing value; declare it `self: inout` to replace that value, or return the new value",
        params[0].span
      )
    )
    case PMInout -> if not inoutAllowed {
      diag.add(
        errorDiagnostic(
          "T0165",
          "the receiver of interface method '" + name +
            "' cannot be `inout`: a call through an interface value cannot assign the caller's variable; declare it `self: in Self`, or make it a method of the record",
          params[0].span
        )
      )
    }
    case PMIn -> ()
  }
}

func checkRecordMemberBodies(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in RecordDecl,
): Unit {
  val ownerGenerics = recordDeclGenericNames(decl)
  val ctx = declGenericContext(decl.generics)
  val fieldLocals = recordFieldLocals(tbl, ctx, decl)
  val selfTy = recordSelfType(tbl, decl, ownerGenerics)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        val ownFnGenerics = extractGenericNames(fn.generics)
        val combinedGenerics: List[String] = newList()
        var g = 0
        while g < ownerGenerics.count {
          combinedGenerics.add(ownerGenerics[g])
          g = g + 1
        }
        var g2 = 0
        while g2 < ownFnGenerics.count {
          combinedGenerics.add(ownFnGenerics[g2])
          g2 = g2 + 1
        }
        val sig0 = resolveMethodSigParts(
          tbl,
          "",
          ownerGenerics,
          fn.generics,
          fn.params,
          fn.ret,
          fn.isAsync,
          fnHasAnnotation(fn, "pure"),
          fnHasAnnotation(fn, "io"),
          false,
          fn.span
        )
        val sig = ResolvedSignature(
          generics = combinedGenerics,
          bounds = sig0.bounds,
          params = substitutesSelfParams(sig0.params, selfTy),
          returnTy = substitutesSelf(sig0.returnTy, selfTy),
          isAsync = sig0.isAsync,
          isHot = sig0.isHot,
          isGenerator = sig0.isGenerator,
          originPackage = sig0.originPackage,
          span = sig0.span,
          isPure = fnHasAnnotation(fn, "pure"),
          isIo = sig0.isIo,
          isEntry = sig0.isEntry,
          isExternFunc = sig0.isExternFunc
        )
        // #6173: a bare field reference/assignment inside a record in-body
        // method (no `self.` prefix) IS a valid, shipped spelling —
        // `x = x + n` means `self.x = self.x + n` — codegen's EPath lowering
        // falls back to `self.<name>` on both backends when the name isn't a
        // local/param (`fctx.className`-keyed `fieldTokens` lookup on MSIL,
        // the JVM `selfFieldType` fallback). `fieldLocals` seeds this exactly
        // like `protectedFieldLocals` does for protected members — found via
        // the #6173 regression battery (`impl_method_self_test.l`) failing
        // T0020 on a previously-clean bare-name field read/write once body-
        // checking turned on without this.
        checkFunctionBody(
          tbl,
          sigs,
          diag,
          withOwnerValueGenerics(fn, decl.generics),
          sig,
          fieldLocals,
          fieldLocals,
          true,
          selfTy
        )
      }
      case RMInvariant(inv) -> checkQuantifiedInvariantConjuncts(tbl, sigs, diag, inv, ownerGenerics, fieldLocals, selfTy)
      case _ -> {
      }
    }
    i = i + 1
  }
}

// #6487: find the `RecordDecl` backing a resolved record/exposed-record
// `SymbolId`, reusing the same symbol-table walk `fieldsOfRecord` (exprs.l)
// does — needed here (rather than `fieldsOfRecord`'s already-`Type`-resolved
// output) because `implTargetFieldLocals` must re-resolve each field through
// `recordFieldLocals` to get `LocalBinding.isMutable`, which `FieldEntry`
// does not carry.
func findRecordDeclByTypeId(tbl: in SymbolTable, tid: in SymbolId): Option[RecordDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, rd) -> {
        if symbolIdEq(did, tid) {
          return Some(value = rd)
        }
      }
      case DKExposedRec(did, rd) -> {
        if symbolIdEq(did, tid) {
          return Some(value = rd)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

func findProtectedDeclByTypeId(tbl: in SymbolTable, tid: in SymbolId): Option[ProtectedTypeDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKProtected(did, pd) -> {
        if symbolIdEq(did, tid) {
          return Some(value = pd)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// #7457: `impl Iface for P` where `P` is a protected type.  The contract
// elaborator moves each impl method into `P` as an `entry` member, so it runs
// under the instance lock, notifies barrier waiters and re-checks `P`'s
// invariants like every other member (§7.5).  An impl method's signature may
// mention `Self` freely (#7550): the elaborator keeps `Self` in the moved
// entry's signature unsubstituted, so MSIL/JVM erase it to `object`/`Object`
// exactly as they erase the interface slot itself — no signature mismatch
// ever arises. Shapes that move cannot represent are rejected here rather
// than miscompiled:
//   - T0136: the impl is declared in a different package than `P` (the
//     methods must land in `P`'s own class);
//   - T0136: `P` or the impl is generic;
//   - T0136: the impl target is not spelled as `P` itself (an alias of `P`
//     would hide the target from the move, which matches on the name);
//   - T0136: an impl method has the same name as one of `P`'s own
//     `entry`/`func` members, or as a method of an earlier impl for `P`
//     (both would become the same locked method);
//   - T0135: an impl method is `async` or declares its own type parameters,
//     exactly as for a protected `func`.
func checkImplOnProtected(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in ImplDecl, items: in List[Item]): Unit {
  val scratch: List[Diagnostic] = newList()
  val ctx = declGenericContext(decl.generics)
  val targetTy = resolveType(tbl, ctx, scratch, decl.target)
  val pdOpt: Option[ProtectedTypeDecl] = match typeIdOfType(targetTy) {
    case Some(tid) -> findProtectedDeclByTypeId(tbl, tid)
    case None -> None
  }
  match pdOpt {
    case None -> ()
    case Some(pd) -> {
      val ifaceSegs = decl.iface.head.segments
      val ifaceName = if ifaceSegs.count == 0 { "" } else { ifaceSegs[ifaceSegs.count - 1] }
      if not itemsDeclareProtected(items, pd.name) {
        diag.add(
          errorDiagnostic(
            "T0136",
            "impl of '" + ifaceName + "' for protected type '" + pd.name + "' must be declared in the package that declares '" +
              pd.name +
              "'; its methods become locked members of the type",
            decl.span
          )
        )
        return
      }
      if not implTargetNamesProtected(decl, pd.name) {
        diag.add(
          errorDiagnostic(
            "T0136",
            "impl of '" + ifaceName + "' for protected type '" + pd.name + "' must name '" + pd.name +
              "' directly as its target, not through an alias",
            decl.span
          )
        )
        return
      }
      val implGeneric = match decl.generics { case Some(_) -> true; case None -> false }
      val targetGeneric = match pd.generics { case Some(_) -> true; case None -> false }
      if implGeneric or targetGeneric {
        diag.add(
          errorDiagnostic(
            "T0136",
            "impl of '" + ifaceName + "' for protected type '" + pd.name +
              "': an impl for a generic protected type is not supported",
            decl.span
          )
        )
        return
      }
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> {
            checkProtectedFuncShape(diag, pd.name, fn)
            if protectedDeclaresMember(pd, fn.name) {
              diag.add(
                errorDiagnostic(
                  "T0136",
                  "impl method '" + fn.name + "' of '" + ifaceName + "' clashes with member '" + fn.name + "' of protected type '" +
                    pd.name +
                    "'; an impl method on a protected type is itself a locked member, so move the body into the impl or rename the member",
                  fn.span
                )
              )
            } else {
              match earlierProtectedImplWithMethod(items, decl, pd.name, fn.name) {
                case Some(otherIface) -> diag.add(
                  errorDiagnostic(
                    "T0136",
                    "impl method '" + fn.name + "' of '" + ifaceName + "' clashes with method '" + fn.name +
                      "' of the impl of '" +
                      otherIface +
                      "' for protected type '" +
                      pd.name +
                      "'; both would become the same locked member of '" +
                      pd.name +
                      "', so rename one of the interface methods",
                    fn.span
                  )
                )
                case None -> ()
              }
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
    }
  }
}

func implTargetNamesProtected(decl: in ImplDecl, name: in String): Bool {
  match decl.target.kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == name
    case _ -> false
  }
}

func implIfaceName(decl: in ImplDecl): String {
  val segs = decl.iface.head.segments
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

// The interface of an impl for protected type `name`, declared in `items`
// before `decl`, that already has a method called `method`.
func earlierProtectedImplWithMethod(
  items: in List[Item], decl: in ImplDecl, name: in String, method: in String
): Option[String] {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(other) -> {
        if sameSpan(other.span, decl.span) {
          return None
        }
        if implTargetNamesProtected(other, name) {
          var m = 0
          while m < other.members.count {
            match other.members[m] {
              case IMplFunc(fn) -> {
                if fn.name == method {
                  return Some(value = implIfaceName(other))
                }
              }
              case _ -> ()
            }
            m = m + 1
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// True when a record or exposed record named `targetName` declares an
// own-body (D037) method called `method` among `items`.
func recordDeclaresOwnBodyMethod(items: in List[Item], targetName: in String, method: in String): Bool {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IRecord(decl) -> if decl.name == targetName and recordBodyDeclaresMethod(decl, method) { return true }
      case IExposedRec(decl) -> if decl.name == targetName and recordBodyDeclaresMethod(decl, method) { return true }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func recordBodyDeclaresMethod(decl: in RecordDecl, method: in String): Bool {
  var m = 0
  while m < decl.members.count {
    match decl.members[m] {
      case RMFunc(fn) -> if fn.name == method { return true }
      case _ -> ()
    }
    m = m + 1
  }
  false
}

// The interface of an impl for the type named `targetName`, declared in
// `items` before `decl`, that already has a method called `method`.
// Generalizes `earlierProtectedImplWithMethod` (whose own-package,
// non-generic, non-aliased restrictions are specific to the
// contract-elaborator move protected types need) to any impl target:
// matched by the RESOLVED type name rather than raw target-AST text, so a
// `type X = R; impl I for X` alias still matches an `impl J for R` for the
// same underlying `R`.
func earlierImplWithMethodForTarget(
  tbl: in SymbolTable,
  items: in List[Item],
  decl: in ImplDecl,
  targetName: in String,
  method: in String,
): Option[String] {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(other) -> {
        if sameSpan(other.span, decl.span) {
          return None
        }
        val scratch: List[Diagnostic] = newList()
        val octx = declGenericContext(other.generics)
        val otherTy = resolveType(tbl, octx, scratch, other.target)
        if simpleTypeNameOf(otherTy) == targetName {
          var m = 0
          while m < other.members.count {
            match other.members[m] {
              case IMplFunc(fn) -> if fn.name == method { return Some(value = implIfaceName(other)) }
              case _ -> ()
            }
            m = m + 1
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// #7626/#7627 review follow-ups: no backend can compile a non-protected
// impl target (record, exposed record, union, opaque type) that declares
// the same method name reachable twice directly on it — MSIL/JVM both
// fail codegen with a duplicate-member error, and the native backend
// (#7600) has no ambiguity diagnostic to fall back on and would silently
// resolve to whichever tier its direct-call index happens to check first.
// Protected types already reject this shape as T0136
// (`checkImplOnProtected`, whose message explains the CONTRACT ELABORATOR
// consequence of moving impl methods into a locked member); this
// generalizes the same "duplicate method name on a shared target"
// detection — reusing `earlierProtectedImplWithMethod`'s pattern via
// `earlierImplWithMethodForTarget` above — to every other target, under a
// new code, T0139, since T0136's protected-only wording does not apply
// here. Detects two shapes:
//   - an impl method whose name matches one of the target's own
//     record-body (D037) methods (#7626);
//   - an impl method whose name matches a method of an EARLIER impl
//     (possibly of a different interface) for the same target.
// Both checks are AST-based over `items` (the file currently being
// checked), so a record's own-body methods and its `impl` blocks need to
// be visible in the same file/package to be caught here — the realistic
// case, since both are ordinarily declared alongside the record itself.
func checkImplMethodNameConflicts(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  decl: in ImplDecl,
  items: in List[Item],
): Unit {
  val scratch: List[Diagnostic] = newList()
  val ctx = declGenericContext(decl.generics)
  val targetTy = resolveType(tbl, ctx, scratch, decl.target)
  val pdOpt: Option[ProtectedTypeDecl] = match typeIdOfType(targetTy) {
    case Some(tid) -> findProtectedDeclByTypeId(tbl, tid)
    case None -> None
  }
  match pdOpt {
    case Some(_) -> ()
    case None -> {
      val targetName = simpleTypeNameOf(targetTy)
      if targetName.length > 0 {
        val ifaceName = implIfaceName(decl)
        var i = 0
        while i < decl.members.count {
          match decl.members[i] {
            case IMplFunc(fn) -> {
              if recordDeclaresOwnBodyMethod(items, targetName, fn.name) {
                diag.add(
                  errorDiagnostic(
                    "T0139",
                    "impl method '" + fn.name + "' of '" + ifaceName + "' has the same name as the own method '" + fn.name + "' of '" +
                      targetName +
                      "'; rename the impl method or the record's own method to disambiguate",
                    fn.span
                  )
                )
              } else {
                match earlierImplWithMethodForTarget(tbl, items, decl, targetName, fn.name) {
                  case Some(otherIface) -> diag.add(
                    errorDiagnostic(
                      "T0139",
                      "impl method '" + fn.name + "' of '" + ifaceName + "' has the same name as method '" +
                        fn.name +
                        "' of the impl of '" +
                        otherIface +
                        "' for '" +
                        targetName +
                        "'; rename one of the interface methods to disambiguate",
                      fn.span
                    )
                  )
                  case None -> ()
                }
              }
            }
            case _ -> ()
          }
          i = i + 1
        }
      }
    }
  }
}

func itemsDeclareProtected(items: in List[Item], name: in String): Bool {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IProtected(pd) -> {
        if pd.name == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func protectedDeclaresMember(pd: in ProtectedTypeDecl, name: in String): Bool {
  var i = 0
  while i < pd.members.count {
    match pd.members[i] {
      case PMEntry(ed) -> {
        if ed.name == name {
          return true
        }
      }
      case PMFunc(fn) -> {
        if fn.name == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// #6487: an impl method's `self` is the impl's TARGET type, not the impl
// block itself — resolve the target's own fields (via
// `findRecordDeclByTypeId` + `recordFieldLocals`, in the target record's OWN
// generic-parameter names) and substitute those names for `selfTy`'s actual
// type arguments (`substituteTyVars`, the same mechanism
// `substituteMethodSig` uses for a call-site method signature) so `impl
// Container[T] for Box[T] { func get(self: in Self): T { self.v } }` types
// `self.v` as the IMPL's own `T`, not the record's. Non-record targets
// (opaque types, unions, …) have no field-enumeration path the checker
// tracks (`fieldsOfRecord`/`inferMemberBase` are record-only too, #6487
// audit found zero in-tree `impl … for <opaque type>` — opaque internals are
// accessed through the `_kernel_host` extern boundary, never `self.field`)
// so they yield an empty list — `self.<anything>` in such a body correctly
// reports T0020 rather than silently degrading, matching `sc.selfChecked`'s
// zero-field-guard fix.
func implTargetFieldLocals(tbl: in SymbolTable, selfTy: in Type): List[LocalBinding] {
  val none: List[LocalBinding] = newList()
  match typeIdOfType(selfTy) {
    case None -> none
    case Some(tid) -> match findRecordDeclByTypeId(tbl, tid) {
      // #7457: an impl method on a protected type is lowered as one of the
      // type's own locked members, so it sees the fields exactly as an
      // `entry`/`func` body does.
      case None -> match findProtectedDeclByTypeId(tbl, tid) {
        case Some(pd) -> protectedFieldLocals(tbl, declGenericContext(pd.generics), pd)
        case None -> none
      }
      case Some(rd) -> {
        val ownCtx = declGenericContext(rd.generics)
        val raw = recordFieldLocals(tbl, ownCtx, rd)
        val gnames = recordDeclGenericNames(rd)
        val targs = match unrefine(selfTy) { case TyUser(_, _, args) -> args; case _ -> newList() }
        val substituted: List[LocalBinding] = newList()
        var i = 0
        while i < raw.count {
          substituted.add(
            LocalBinding(name = raw[i].name, ty = substituteTyVars(raw[i].ty, gnames, targs), isMutable = raw[i].isMutable)
          )
          i = i + 1
        }
        substituted
      }
    }
  }
}

// #6487: `IMplFunc` (impl-block method) bodies were never routed through
// `checkFunctionBody` — `checkImplConformance` (above) only validates the
// SIGNATURE against the interface, never the body — so an ill-typed impl
// method body compiled with zero diagnostics, the larger sibling of the
// `RMFunc` gap above (impl/record methods are everywhere: stdlib, every
// ecosystem library, the compiler itself). `self` is never a real entry in
// `fn.params` for an impl method (the parser's `injectSelfIfNeeded` is
// deliberately NOT applied to `parseImplMemberOpt` — an explicit `self: in
// Self` param, when the user writes one, is the only case index 0 is
// literally named `self`; `resolveMethodSigParts`'s existing drop-by-name
// check handles both spellings identically), so `sig.params` from
// `resolveMethodSigParts` already excludes it correctly either way.
//
// #6173 (found via the battery run): a bare field reference/assignment
// inside an impl method body (no `self.` prefix) IS a valid, shipped
// spelling too — codegen's EPath lowering falls back to `self.<name>` on
// both backends (the same `fctx.className`-keyed fallback
// `checkRecordMemberBodies` documents) — so `fieldLocals` seeds bare-name
// scope resolution here as well, not only the `self.field` map.
//
// #6417 (found via the same battery run): an impl method's declared return
// type may literally be `Self` (`func dup(self: in Self): Self { … }`,
// mirroring `docs/01`'s `Cloneable` example) — `resolveMethodSigParts`
// leaves that as the unsubstituted `TySelf` placeholder, which
// `typeAssignable` never accepts from a concrete `TyUser` body value, so the
// return type is substituted through `selfTy` (`substitutesSelf`, the same
// helper `checkImplConformance` already uses for the interface-conformance
// check) before the T0070 check runs.
func checkImplMemberBodies(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in ImplDecl,
): Unit {
  val implGenerics = extractGenericNames(decl.generics)
  val ctx = newGenericContext()
  if implGenerics.count > 0 {
    gctxPush(ctx, implGenerics)
  }
  // The impl target's own declaration-position validation is
  // `checkImplConformance`'s job (against the shared `diag`); re-resolving it
  // here goes to a scratch list to avoid a duplicate diagnostic.
  val scratch: List[Diagnostic] = newList()
  val selfTy = resolveType(tbl, ctx, scratch, decl.target)
  val fieldLocals = implTargetFieldLocals(tbl, selfTy)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        val ownFnGenerics = extractGenericNames(fn.generics)
        val combinedGenerics: List[String] = newList()
        var g = 0
        while g < implGenerics.count {
          combinedGenerics.add(implGenerics[g])
          g = g + 1
        }
        var g2 = 0
        while g2 < ownFnGenerics.count {
          combinedGenerics.add(ownFnGenerics[g2])
          g2 = g2 + 1
        }
        val sig0 = resolveMethodSigParts(
          tbl,
          "",
          implGenerics,
          fn.generics,
          fn.params,
          fn.ret,
          fn.isAsync,
          fnHasAnnotation(fn, "pure"),
          fnHasAnnotation(fn, "io"),
          false,
          fn.span
        )
        val sig = ResolvedSignature(
          generics = combinedGenerics,
          bounds = sig0.bounds,
          params = substitutesSelfParams(sig0.params, selfTy),
          returnTy = substitutesSelf(sig0.returnTy, selfTy),
          isAsync = sig0.isAsync,
          isHot = sig0.isHot,
          isGenerator = sig0.isGenerator,
          originPackage = sig0.originPackage,
          span = sig0.span,
          isPure = fnHasAnnotation(fn, "pure"),
          isIo = sig0.isIo,
          isEntry = sig0.isEntry,
          isExternFunc = sig0.isExternFunc
        )
        // An inherited interface default (`Lyric.ImplDefaults`) was written
        // against the interface, which has no fields: none of the target's
        // fields is in its scope by bare name (#8264).
        val bareFieldLocals: List[LocalBinding] = if hasMarkerAnnotation(fn.annotations, inheritedDefaultAnnotationName()) {
          newList()
        } else {
          fieldLocals
        }
        checkFunctionBody(tbl, sigs, diag, fn, sig, bareFieldLocals, fieldLocals, true, selfTy)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// One method's name, parameter count (receiver included) and span, for
// `checkSameArityMethods`.
record MethodHead {
  name: String
  arity: Int
  span: Span
}

// T0162: two methods of one name in one record, interface or `impl` must
// differ in their number of parameters, as two functions of one name in a
// package must (T0001).  This is a limit of this compiler's dispatch-key
// scheme, not of the CLR or the JVM, which overload by full signature: the
// MSIL, JVM and native backends key a method by its type, name and
// parameter count, so two same-count overloads would silently bind to one
// (#8085).
func checkSameArityMethods(diag: in List[Diagnostic], owner: in String, heads: in List[MethodHead]): Unit {
  var j = 1
  while j < heads.count {
    var k = 0
    var clash = false
    while k < j and not clash {
      if heads[k].name == heads[j].name and heads[k].arity == heads[j].arity {
        clash = true
      }
      k = k + 1
    }
    if clash {
      diag.add(
        errorDiagnostic(
          "T0162",
          "method '" + heads[j].name + "' of '" + owner + "' has the same number of parameters (" + toString(heads[j].arity) +
            ") as an earlier method of that name; this compiler tells a type's methods of one name apart by their " +
            "number of parameters, so overloads must differ in it",
          heads[j].span
        )
      )
    }
    j = j + 1
  }
}

// T0209: a protected type's entries and functions are told apart by name
// alone, so two members of one name are rejected whatever their parameter
// counts.  A record's methods may be overloaded by parameter count (T0162
// covers same-count clashes); the protected-object lowering has no such key
// on the .NET target, where a call to the second declaration would bind to
// the first (#8104).
func checkProtectedMemberOverloads(diag: in List[Diagnostic], decl: in ProtectedTypeDecl): Unit {
  val seen: List[String] = newList()
  for m in decl.members {
    val head: Option[MethodHead] = match m {
      case PMEntry(e) -> Some(
        value = MethodHead(
          name = e.name,
          arity = e.params.count,
          span = e.span
        )
      )
      case PMFunc(fn) -> Some(
        value = MethodHead(
          name = fn.name,
          arity = fn.params.count,
          span = fn.span
        )
      )
      case _ -> None
    }
    match head {
      case Some(h) -> {
        if seen.contains(h.name) {
          diag.add(
            errorDiagnostic(
              "T0209",
              "member '" + h.name + "' of protected type '" + decl.name +
                "' is declared more than once; a protected type's members are told apart by name, so they cannot be overloaded (give each its own name)",
              h.span
            )
          )
        } else {
          seen.add(h.name)
        }
      }
      case None -> ()
    }
  }
}

func recordMethodHeads(members: in List[RecordMember]): List[MethodHead] {
  val acc: List[MethodHead] = newList()
  for m in members {
    match m {
      case RMFunc(fn) -> acc.add(MethodHead(name = fn.name, arity = fn.params.count, span = fn.span))
      case _ -> ()
    }
  }
  acc
}

func interfaceMethodHeads(members: in List[InterfaceMember]): List[MethodHead] {
  val acc: List[MethodHead] = newList()
  for m in members {
    match m {
      case IMSig(sig) -> acc.add(MethodHead(name = sig.name, arity = sig.params.count, span = sig.span))
      case IMFunc(fn) -> acc.add(MethodHead(name = fn.name, arity = fn.params.count, span = fn.span))
      case IMAssoc(_) -> ()
    }
  }
  acc
}

func implMethodHeads(members: in List[ImplMember]): List[MethodHead] {
  val acc: List[MethodHead] = newList()
  for m in members {
    match m {
      case IMplFunc(fn) -> acc.add(MethodHead(name = fn.name, arity = fn.params.count, span = fn.span))
      case IMplAssoc(_) -> ()
    }
  }
  acc
}

func checkDeclTypeRefs(tbl: in SymbolTable, diag: in List[Diagnostic], items: in List[Item]): Unit {
  val emptyCtx = newGenericContext()
  var i = 0
  while i < items.count {
    checkNoPlainDerive(diag, items[i].annotations)
    match items[i].kind {
      case IRecord(decl) -> {
        if decl.isForeign {
          checkForeignRecordDecl(tbl, diag, decl)
        }
        if not decl.isRef and not decl.isForeign and recordDeclHasVarField(decl) {
          diag.add(
            warningDiagnostic(
              "W0031",
              "record '" + decl.name +
                "' has `var` fields, so it has identity and is shared on assignment; declare it `ref record " +
                decl.name +
                "` (D222)",
              decl.span
            )
          )
        }
        checkRecordDeclTypes(tbl, diag, decl)
        checkRecordArithDerives(diag, items[i].annotations, decl)
        checkArrayFieldDerives(
          tbl,
          diag,
          items[i].annotations,
          decl.name,
          decl.generics,
          recordFieldTypeExprs(decl),
          decl.span
        )
        checkSameArityMethods(diag, decl.name, recordMethodHeads(decl.members))
      }
      case IExposedRec(decl) -> {
        checkRecordDeclTypes(tbl, diag, decl)
        checkRecordArithDerives(diag, items[i].annotations, decl)
        checkArrayFieldDerives(
          tbl,
          diag,
          items[i].annotations,
          decl.name,
          decl.generics,
          recordFieldTypeExprs(decl),
          decl.span
        )
        checkSameArityMethods(diag, decl.name, recordMethodHeads(decl.members))
      }
      case IUnion(decl) -> {
        checkUnionDeclTypes(tbl, diag, decl)
        checkArrayFieldDerives(
          tbl,
          diag,
          items[i].annotations,
          decl.name,
          decl.generics,
          unionFieldTypeExprs(decl),
          decl.span
        )
      }
      case IInterface(decl) -> {
        checkInterfaceDeclTypes(tbl, diag, decl)
        checkSameArityMethods(diag, decl.name, interfaceMethodHeads(decl.members))
      }
      case IOpaque(decl) -> {
        checkOpaqueDeclTypes(tbl, diag, decl)
      }
      case IProtected(decl) -> {
        checkProtectedDeclTypes(tbl, diag, decl)
        checkProtectedMemberOverloads(diag, decl)
        checkProtectedValueGenericVisibility(diag, decl, items[i].visibility)
      }
      case ITypeAlias(decl) -> {
        val ctx = declGenericContext(decl.generics)
        val _ = resolveType(tbl, ctx, diag, decl.rhs)
      }
      case IConst(decl) -> {
        val _ = resolveType(tbl, emptyCtx, diag, decl.ty)
      }
      case IVal(decl) -> {
        match decl.ty {
          case Some(te) -> {
            val _ = resolveType(tbl, emptyCtx, diag, te)
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. Config block well-formedness (D046 / docs/25-config-blocks.md).
// ─────────────────────────────────────────────────────────────────────────────
// The bare single-segment name of a config field's declared type, or "" for
// any shape outside the v1 set (qualified paths, generics, function types).
func configFieldTypeName(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
    case TRefined(path, _) -> if path.segments.count == 1 { path.segments[0] } else { "" }
    case _ -> ""
  }
}

// G0009 for a malformed range refinement on a config field (see
// `configRangeProblem`).  Returns the range when it is well formed, so the
// caller can check the default against it (G0010).
func checkConfigFieldRange(diag: in List[Diagnostic], cd: in ConfigDecl, f: in ConfigField): Option[RangeBound] {
  match f.ty.kind {
    case TRefined(_, rb) -> {
      val problem = configRangeProblem(configFieldTypeName(f.ty), rb)
      if problem.length > 0 {
        diag.add(errorDiagnostic("G0009", "config field '" + cd.name + "." + f.name + "' " + problem, f.ty.span))
        None
      } else {
        Some(value = rb)
      }
    }
    case _ -> None
  }
}

// An aspect's own `config { }` fields may be ranges too (#7229).  Their
// values are compile-time literals, so a malformed range is G0009 and a
// default outside it G0010, as for a module-scope config block.  The other
// config-block rules (allowed types, literal defaults) are the weaver's
// concern for aspects; a `from`-instance override is range-checked by the
// weaver against the template's field.
func checkAspectConfigRanges(diag: in List[Diagnostic], decl: in AspectDecl): Unit {
  val cd = ConfigDecl(name = decl.name, from = None, fields = decl.config, span = decl.span)
  var i = 0
  while i < decl.config.count {
    val f = decl.config[i]
    match checkConfigFieldRange(diag, cd, f) {
      case Some(rb) -> match f.default {
        case Some(d) -> {
          val v = foldLiteralBound(d)
          if v.ok and not literalInRange(v, rb) {
            diag.add(
              errorDiagnostic(
                "G0010",
                "config default for '" + decl.name + "." + f.name + "' is outside the field's range",
                d.span
              )
            )
          }
        }
        case None -> ()
      }
      case None -> ()
    }
    i = i + 1
  }
}

// An integer field takes integer bounds within its own range; a floating
// field takes either.
// Whether a literal default can initialise a config field of type `tyName`.
// Int literals widen to Long / Float / Double; Float literals fit Float /
// Double; everything else must match exactly.
func configLiteralFitsType(lit: in Literal, tyName: in String): Bool {
  match lit {
    case LBool(_) -> tyName == "Bool"
    case LInt(_, _, _) -> tyName == "Int" or tyName == "Long" or tyName == "Float" or tyName == "Double"
    case LFloat(_, _, _) -> tyName == "Float" or tyName == "Double"
    case LString(_) -> tyName == "String"
    case LTripleString(_) -> tyName == "String"
    case LRawString(_) -> tyName == "String"
    case _ -> false
  }
}

// Well-formedness check for a `config` block.  v1 enforces:
//   * Field type is one of Bool / Int / Long / Float / Double / String, or a
//     range of Int / Long / Float / Double with literal, non-empty bounds
//     (G0009, #7229); enums and lists are deferred.
//   * Field default, when present, is a literal of the declared type,
//     optionally negated for numeric fields, and inside the field's range
//     when it has one (G0010).
//   * Field names are unique within the block (G0013).
// The MSIL config lowering relies on these guarantees: an unchecked field
// type silently zero-fills the default path and emits invalid IL on the
// env-parse path (#2993).
func checkConfigBlock(diag: in List[Diagnostic], cd: in ConfigDecl): Unit {
  val seen: List[String] = newList()
  var i = 0
  while i < cd.fields.count {
    val f = cd.fields[i]
    if listContainsStr(seen, f.name) {
      diag.add(errorDiagnostic("G0013", "duplicate field '" + f.name + "' in config block '" + cd.name + "'", f.span))
    } else {
      seen.add(f.name)
    }
    val tyName = configFieldTypeName(f.ty)
    val isRefined = match f.ty.kind { case TRefined(_, _) -> true; case _ -> false }
    val numeric = tyName == "Int" or tyName == "Long" or tyName == "Float" or tyName == "Double"
    val allowed = if isRefined { numeric } else { numeric or tyName == "Bool" or tyName == "String" }
    if not allowed {
      diag.add(
        errorDiagnostic(
          "G0009",
          "config field '" + cd.name + "." + f.name +
            "' has a type not allowed in a config block; allowed types: Bool, Int, Long, Float, Double, String, and a range of Int, Long, Float or Double",
          f.ty.span
        )
      )
    } else {
      val range = checkConfigFieldRange(diag, cd, f)
      match f.default {
        case Some(d) -> {
          val ok = match d.kind {
            case ELiteral(lit) -> configLiteralFitsType(lit, tyName)
            case EPrefix(op, inner) -> match op {
              case PreNeg -> match inner.kind {
                case ELiteral(lit2) -> match lit2 {
                  case LInt(_, _, _) -> configLiteralFitsType(
                    lit2,
                    tyName
                  )
                  case LFloat(_, _, _) -> configLiteralFitsType(
                    lit2,
                    tyName
                  )
                  case _ -> false
                }
                case _ -> false
              }
              case _ -> false
            }
            case _ -> false
          }
          if not ok {
            diag.add(
              errorDiagnostic(
                "G0010",
                "config default for '" + cd.name + "." + f.name + "' must be a literal " + tyName + " constant",
                d.span
              )
            )
          } else {
            match range {
              case Some(rb) -> if not literalInRange(foldLiteralBound(d), rb) {
                diag.add(
                  errorDiagnostic("G0010", "config default for '" + cd.name + "." + f.name + "' is outside the field's range", d.span)
                )
              }
              case None -> ()
            }
          }
        }
        case None -> {
        }
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8c. Declared initialisers (#7811).
// ─────────────────────────────────────────────────────────────────────────────
// An annotated module-level `val`'s initialiser, a field's default and a
// parameter's default each initialise a slot of their declared type, so they
// are checked exactly like an annotated local binding's initialiser: inferred
// against the declared type (T0060 on a mismatch, T0015 for an integer
// literal out of range) and any implicit widening recorded as a conversion
// site, which `Lyric.Mono.desugarCheckedFile` makes explicit.  They are
// checked once, here, in the declaring package: a module `val` read only
// resolves its declared type, and a default is spliced into each call that
// omits the argument after desugaring.
//
// The initialiser sees the module's names only (no locals; a default does
// not see the other parameters).  The declared type was already resolved,
// with any error reported, by the declaration's own type-reference check,
// so it is resolved here into a scratch list.
func checkDeclaredInit(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  genericNames: in List[String],
  te: in TypeExpr,
  init: in Expr,
  subject: in String,
  initNoun: in String,
  sp: in Span,
): Unit {
  val noRte: Option[TypeExpr] = None
  val noSelfFields: Map[String, Type] = newMap()
  val sc = newScopeForFunction(TyError, genericNames, noRte, noSelfFields, false, TyError)
  checkDeclaredInitIn(sc, tbl, sigs, diag, genericNames, te, init, subject, initNoun, sp)
}

// `checkDeclaredInit` against a caller-supplied scope, for initialisers that
// read sibling bindings (a wire member reads the other members, #8539).
func checkDeclaredInitIn(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  genericNames: in List[String],
  te: in TypeExpr,
  init: in Expr,
  subject: in String,
  initNoun: in String,
  sp: in Span,
): Unit {
  val ctx = newGenericContext()
  if genericNames.count > 0 {
    gctxPush(ctx, genericNames)
  }
  val scratch: List[Diagnostic] = newList()
  val declT = resolveType(tbl, ctx, scratch, te)
  val initType = inferExprExpected(sc, tbl, sigs, diag, init, declT)
  val literalOutOfRange = reportIntLiteralOutOfRange(declT, init, diag)
  if not literalOutOfRange and not argSatisfiesParam(tbl, declT, initType) {
    diag.add(
      errorDiagnostic(
        "T0060",
        subject + " declared as " + renderTypeExpr(te, declT) + " but " + initNoun + " " +
          hasTypeOrEmptyLiteral(initType, init) +
          typeMismatchHint(tbl, declT, initType),
        sp
      )
    )
  }
  recordUnsignedWidening(tbl, declT, initType, init)
  checkRefinedLiteralBound(declT, init, diag)
}

func annotationsHave(anns: in List[Annotation], name: in String): Bool {
  for ann in anns {
    if ann.name.segments.count == 1 and ann.name.segments[0] == name {
      return true
    }
  }
  false
}

func concatGenericNames(outer: in List[String], own: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  for n in outer {
    names.add(n)
  }
  for n in extractGenericNames(own) {
    names.add(n)
  }
  names
}

func checkParamDefaults(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  genericNames: in List[String],
  fnName: in String,
  params: in List[Param],
): Unit {
  for p in params {
    match p.dflt {
      case Some(d) -> checkDeclaredInit(
        tbl,
        sigs,
        diag,
        genericNames,
        p.ty,
        d,
        "parameter '" + p.name + "' of '" + fnName + "'",
        "its default",
        d.span
      )
      case None -> ()
    }
  }
}

func checkFieldDefault(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  genericNames: in List[String],
  typeName: in String,
  fieldName: in String,
  ty: in TypeExpr,
  dflt: in Option[Expr],
): Unit {
  match dflt {
    case Some(d) -> checkDeclaredInit(
      tbl,
      sigs,
      diag,
      genericNames,
      ty,
      d,
      "field '" + typeName + "." + fieldName + "'",
      "its default",
      d.span
    )
    case None -> ()
  }
}

// The name a `bind` member is reachable under: its interface's simple name.
func wireBindName(iface: in TypeExpr): String {
  match iface.kind {
    case TRef(path) -> path.segments[path.segments.count - 1]
    case TGenericApp(head, _) -> head.segments[head.segments.count - 1]
    case _ -> "<bind>"
  }
}

// #8539: every wire member's initialiser is checked against its declared
// type.  The expander has already turned each `contributes` entry, the
// synthesised `List[T]` collection and the `<T>ByKey` map into typed locals,
// so those are covered by the same rule.  Members read one another in any
// order (the backends sort them), so every member with a written type is
// bound up front; an unannotated local is typed from its initialiser once the
// members it reads are bound.
func checkWireInits(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in WireDecl,
): Unit {
  val noGenerics: List[String] = newList()
  val noRte: Option[TypeExpr] = None
  val noSelfFields: Map[String, Type] = newMap()
  val sc = newScopeForFunction(TyError, noGenerics, noRte, noSelfFields, false, TyError)
  val ctx = newGenericContext()
  val scratch: List[Diagnostic] = newList()
  // A member spliced from a wire template carries references qualified for
  // the template's own imports, which the including package's scope cannot
  // always resolve (#6505): only a type mismatch is reported, never a name
  // the including file cannot see.  An unresolved reference types as
  // `TyError`, which matches anything.
  val quiet: List[Diagnostic] = newList()
  for p in decl.params {
    scopeAdd(sc, LocalBinding(name = p.name, ty = resolveType(tbl, ctx, scratch, p.ty), isMutable = false))
  }
  val untyped: List[Int] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case WMProvided(n, ty, _) -> scopeAdd(
        sc,
        LocalBinding(name = n, ty = resolveType(tbl, ctx, scratch, ty), isMutable = false)
      )
      case WMSingleton(n, ty, _, _) -> scopeAdd(
        sc,
        LocalBinding(
          name = n,
          ty = resolveType(tbl, ctx, scratch, ty),
          isMutable = false
        )
      )
      case WMScoped(_, n, ty, _, _) -> scopeAdd(
        sc,
        LocalBinding(
          name = n,
          ty = resolveType(tbl, ctx, scratch, ty),
          isMutable = false
        )
      )
      case WMBind(iface, _, _) -> scopeAdd(
        sc,
        LocalBinding(
          name = wireBindName(iface),
          ty = resolveType(tbl, ctx, scratch, iface),
          isMutable = false
        )
      )
      case WMLocal(n, Some(ty), _, _) -> scopeAdd(
        sc,
        LocalBinding(
          name = n,
          ty = resolveType(tbl, ctx, scratch, ty),
          isMutable = false
        )
      )
      case WMLocal(_, None, _, _) -> untyped.add(i)
      case _ -> {
      }
    }
    i = i + 1
  }
  var pending = untyped
  var progressed = true
  while progressed and pending.count > 0 {
    progressed = false
    val still: List[Int] = newList()
    for idx in pending {
      match decl.members[idx] {
        case WMLocal(n, _, init, _) -> {
          val trial: List[Diagnostic] = newList()
          val t = inferExpr(sc, tbl, sigs, trial, init)
          if trial.count == 0 {
            scopeAdd(sc, LocalBinding(name = n, ty = t, isMutable = false))
            progressed = true
          } else {
            still.add(idx)
          }
        }
        case _ -> {
        }
      }
    }
    pending = still
  }
  for idx in pending {
    match decl.members[idx] {
      case WMLocal(n, _, init, _) -> {
        val t = inferExpr(sc, tbl, sigs, quiet, init)
        scopeAdd(sc, LocalBinding(name = n, ty = t, isMutable = false))
      }
      case _ -> {
      }
    }
  }
  var j = 0
  while j < decl.members.count {
    match decl.members[j] {
      case WMSingleton(n, ty, init, sp) -> checkDeclaredInitIn(
        sc,
        tbl,
        sigs,
        quiet,
        noGenerics,
        ty,
        init,
        "wire member '" + n + "'",
        "initialiser",
        sp
      )
      case WMScoped(_, n, ty, init, sp) -> checkDeclaredInitIn(
        sc,
        tbl,
        sigs,
        quiet,
        noGenerics,
        ty,
        init,
        "wire member '" + n + "'",
        "initialiser",
        sp
      )
      case WMBind(iface, provider, sp) -> checkDeclaredInitIn(
        sc,
        tbl,
        sigs,
        quiet,
        noGenerics,
        iface,
        provider,
        "wire binding '" + wireBindName(iface) + "'",
        "provider",
        sp
      )
      case WMLocal(n, Some(ty), init, sp) -> checkDeclaredInitIn(
        sc,
        tbl,
        sigs,
        quiet,
        noGenerics,
        ty,
        init,
        "wire member '" + n + "'",
        "initialiser",
        sp
      )
      case _ -> {
      }
    }
    j = j + 1
  }
  for d in quiet {
    if d.code == "T0060" {
      diag.add(d)
    }
  }
}

func checkItemDeclaredInits(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  item: in Item,
): Unit {
  val noGenerics: List[String] = newList()
  match item.kind {
    // A fixture's initialiser is checked as the `val` it becomes (#8308).
    case IFixture(fd) -> checkItemDeclaredInits(
      tbl,
      sigs,
      diag,
      Item(
        docComments = item.docComments,
        annotations = item.annotations,
        visibility = item.visibility,
        kind = IVal(decl = fixtureAsVal(fd)),
        span = item.span
      )
    )
    // An `@asyncLocal` value's initialiser is a `()` placeholder: the
    // backend constructs the `AsyncLocal` slot itself, as it supplies an
    // `@externTarget` function's body.
    // An unannotated value's initialiser is inferred once here too, so its
    // errors are reported at the declaration, used or not (#7777).  A name a
    // destructuring `val` projects out of its synthesized temporary is
    // skipped: the temporary carries the user's initialiser, and a shape
    // mismatch is T0144 (`recordModuleValTypes`).
    case IVal(decl) -> match decl.ty {
      case Some(te) -> if not annotationsHave(item.annotations, "asyncLocal") {
        checkDeclaredInit(tbl, sigs, diag, noGenerics, te, decl.init, "val binding", "initialiser", decl.span)
      }
      case None -> match projectedTemp(decl.init) {
        case Some(_) -> ()
        case None -> {
          val noRte: Option[TypeExpr] = None
          val noSelfFields: Map[String, Type] = newMap()
          val sc = newScopeForFunction(TyError, noGenerics, noRte, noSelfFields, false, TyError)
          val _ = inferExpr(sc, tbl, sigs, diag, decl.init)
        }
      }
    }
    case IWire(decl) -> checkWireInits(tbl, sigs, diag, decl)
    case IFunc(decl) -> {
      checkParamDefaults(tbl, sigs, diag, extractGenericNames(decl.generics), decl.name, decl.params)
      checkShadowedExtension(tbl, sigs, diag, decl)
    }
    case IExternFunc(decl) -> checkParamDefaults(tbl, sigs, diag, noGenerics, decl.name, decl.params)
    case IRecord(decl) -> checkRecordDeclaredInits(tbl, sigs, diag, decl)
    case IExposedRec(decl) -> checkRecordDeclaredInits(tbl, sigs, diag, decl)
    case IOpaque(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case OMField(fd) -> {
            checkFieldDefault(tbl, sigs, diag, owner, decl.name, fd.name, fd.ty, fd.dflt)
            noteFieldZeroDefault(tbl, diag, owner, decl.name, fd)
          }
          case OMInvariant(_) -> ()
        }
      }
    }
    case IProtected(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case PMField(pf) -> match pf {
            case PFVar(name, ty, init, _, _, sp) -> {
              checkFieldDefault(tbl, sigs, diag, owner, decl.name, name, ty, init)
              noteFieldZeroDefaultOf(tbl, diag, owner, decl.name, name, ty, init, sp)
            }
            case PFLet(name, ty, init, _, _, sp) -> {
              checkFieldDefault(tbl, sigs, diag, owner, decl.name, name, ty, init)
              noteFieldZeroDefaultOf(tbl, diag, owner, decl.name, name, ty, init, sp)
            }
            case PFImmutable(fd) -> {
              checkFieldDefault(tbl, sigs, diag, owner, decl.name, fd.name, fd.ty, fd.dflt)
              noteFieldZeroDefault(tbl, diag, owner, decl.name, fd)
            }
          }
          case PMEntry(ed) -> checkParamDefaults(tbl, sigs, diag, owner, ed.name, ed.params)
          case PMFunc(fn) -> checkParamDefaults(tbl, sigs, diag, concatGenericNames(owner, fn.generics), fn.name, fn.params)
          case PMInvariant(_) -> ()
        }
      }
    }
    case IInterface(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case IMSig(sig) -> checkParamDefaults(
            tbl,
            sigs,
            diag,
            concatGenericNames(owner, sig.generics),
            sig.name,
            sig.params
          )
          case IMFunc(fn) -> checkParamDefaults(tbl, sigs, diag, concatGenericNames(owner, fn.generics), fn.name, fn.params)
          case IMAssoc(_) -> ()
        }
      }
    }
    case IImpl(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case IMplFunc(fn) -> checkParamDefaults(tbl, sigs, diag, concatGenericNames(owner, fn.generics), fn.name, fn.params)
          case IMplAssoc(_) -> ()
        }
      }
    }
    case _ -> ()
  }
}

// A field of array type with no default is filled with its element type's
// zero value (D167); T0156 when the element type has none.
func noteFieldZeroDefault(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  genericNames: in List[String],
  typeName: in String,
  fd: in FieldDecl,
): Unit {
  noteFieldZeroDefaultOf(tbl, diag, genericNames, typeName, fd.name, fd.ty, fd.dflt, fd.span)
}

func noteFieldZeroDefaultOf(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  genericNames: in List[String],
  typeName: in String,
  fieldName: in String,
  fieldTy: in TypeExpr,
  dflt: in Option[Expr],
  fieldSpan: in Span,
): Unit {
  val hasDefault = match dflt { case Some(_) -> true; case None -> false }
  if hasDefault {
    return
  }
  val ctx = newGenericContext()
  if genericNames.count > 0 {
    gctxPush(ctx, genericNames)
  }
  val scratch: List[Diagnostic] = newList()
  val declT = resolveType(tbl, ctx, scratch, fieldTy)
  // A field whose element type is a type variable is zero filled by each
  // construction that leaves it out, at the instantiated element type
  // (`noteCtorZeroArgs`), so it is not an error here.
  if typeMentionsTyVar(declT) {
    return
  }
  noteArrayZeroInit(
    tbl,
    diag,
    declT,
    recordCopySiteKey(fieldSpan),
    fieldSpan,
    "field '" + typeName + "." + fieldName + "'"
  )
}

func checkRecordDeclaredInits(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in RecordDecl,
): Unit {
  val owner = recordDeclGenericNames(decl)
  for m in decl.members {
    match m {
      case RMField(fd) -> {
        checkFieldDefault(tbl, sigs, diag, owner, decl.name, fd.name, fd.ty, fd.dflt)
        noteFieldZeroDefault(tbl, diag, owner, decl.name, fd)
      }
      case RMFunc(fn) -> checkParamDefaults(tbl, sigs, diag, concatGenericNames(owner, fn.generics), fn.name, fn.params)
      case RMInvariant(_) -> ()
    }
  }
}

// T0170 (a warning): a dot-named function `T.m` this package declares for a
// type another package declares (an extension) whose parameters after the
// receiver are, in number and type, those of one of `T`'s own functions
// named `m` (declared in its body or by its declaring package).  A method
// call, and a call through the type, binds the type's own function whenever
// it applies (D181), so the extension is reached only through its package
// (`Pkg.T.m(x)`).
func checkShadowedExtension(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in FunctionDecl,
): Unit {
  val dot = lastIndexOfRaw(decl.name, ".")
  if dot <= 0 or decl.params.count == 0 {
    return
  }
  val member = decl.name.substring(dot + 1)
  val curPkg = symTableScopePkg(tbl)
  val name = match mapGet(tbl.dotNameRenames, curPkg + "|" + decl.name) { case Some(n) -> n; case None -> decl.name }
  for ext in dotNamedSigsAnyArity(sigs, name) {
    if sigPackage(tbl, ext) == curPkg and ext.params.count == decl.params.count and ext.params.count > 0 {
      val recv = ext.params[0].ty
      match dotNamedDeclaringPackage(tbl, recv) {
        case Some(ownPkg) -> if ownPkg.length > 0 and ownPkg != curPkg {
          val extRest = dropReceiverParam(ext).params
          var shadowed = false
          for own in dotNamedSigsAnyArity(sigs, name) {
            if sigPackage(tbl, own) == ownPkg and sameParamTypes(dropReceiverParam(own).params, extRest) {
              shadowed = true
            }
          }
          match unrefine(recv) {
            case TyUser(tid, _, targs) -> {
              for e in symTableMethodSigs(tbl, tid, member) {
                if sameParamTypes(substituteMethodSig(e, unrefine(recv), targs).params, extRest) {
                  shadowed = true
                }
              }
            }
            case _ -> ()
          }
          if shadowed {
            diag.add(
              warningDiagnostic(
                "T0170",
                "'" + decl.name + "' duplicates a method of '" + decl.name.substring(0, dot) + "' declared by " + ownPkg +
                  ", which a method call or a call through the type always binds instead; this function is reached only as '" +
                  curPkg +
                  "." +
                  decl.name +
                  "(...)' (rename it, or change its parameters)",
                decl.span
              )
            )
          }
        }
        case None -> ()
      }
      return
    }
  }
}

func sameParamTypes(a: in List[ResolvedParam], b: in List[ResolvedParam]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if renderType(a[i].ty) != renderType(b[i].ty) {
      return false
    }
    i = i + 1
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public entry points.
// ─────────────────────────────────────────────────────────────────────────────
// Imported items tagged with their declaring package, so each package's
// signatures resolve against its own declarations (not one flat table).
@stable(since = "0.1")
pub record ImportedPackage {
  // Dotted spelling of a module path (`Std.Regex`), or "" for the empty path.
  name: String
  items: List[Item]
  /// Dotted names of the packages this package itself imports.  Drives the
  /// tier-2 (declared-imports) preference when this package's own signatures
  /// are resolved, so a same-named type exported by two sibling packages binds
  /// to the one THIS package imports instead of last-registered-wins (#2282).
  imports: List[String]
  /// The subset of `imports` this package imports whole (`import P`, not
  /// selective or aliased).
  wholeImports: List[String]
  /// The packages this package re-exports whole (`pub use P`, docs/01
  /// §9.3): the subset of `wholeImports` a file importing this package
  /// whole sees bare, transitively (docs/70 §4.3, D311).
  reexports: List[String] = newList()
}

func dottedPackageName(path: in ModulePath): String {
  modulePathJoin(path.segments)
}

// The dotted names of every package a file explicitly imports.  Public so the
// MSIL / JVM bridges and tests can build `ImportedPackage.imports` from a
// parsed `SourceFile.imports` with the same dotted spelling the scope tiers
// compare against.
pub func collectImportNames(imports: in List[ImportDecl]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < imports.count {
    if not imports[i].isExtern {
      names.add(dottedPackageName(imports[i].path))
    }
    i = i + 1
  }
  names
}

// The dotted names of the packages `imports` imports whole: neither
// selective (`import P.{f}`) nor aliased (`import P as Q`), nor extern.
pub func collectWholeImportNames(imports: in List[ImportDecl]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if not imp.isExtern and isWholeImportForm(imp) {
      val pkg = dottedPackageName(imp.path)
      if not names.contains(pkg) {
        names.add(pkg)
      }
    }
    i = i + 1
  }
  names
}

// The dotted names of the packages `imports` re-exports whole (`pub use P`).
pub func collectReexportNames(imports: in List[ImportDecl]): List[String] {
  val names: List[String] = newList()
  for imp in imports {
    if imp.isPubUse and not imp.isExtern and isWholeImportForm(imp) {
      val pkg = dottedPackageName(imp.path)
      if not names.contains(pkg) {
        names.add(pkg)
      }
    }
  }
  names
}

// `<package>::<name>` for each name `imports` imports selectively.
pub func collectSelectedImportNames(imports: in List[ImportDecl]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if not imp.isExtern {
      match imp.selector {
        case Some(sel) -> {
          val items: List[ImportItem] = match sel {
            case ISGroup(group) -> group
            case ISSingle(one) -> {
              val single: List[ImportItem] = newList()
              single.add(one)
              single
            }
          }
          for item in items {
            names.add(dottedPackageName(imp.path) + "::" + item.name)
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  names
}

func isWholeImportForm(imp: in ImportDecl): Bool {
  match imp.selector {
    case Some(_) -> false
    case None -> match imp.asAlias { case Some(_) -> false; case None -> true }
  }
}

// What one list of imports makes visible (docs/01 §9.2): the packages it
// imports whole, widened to the packages those re-export (`pub use`, D311), the
// `<package>|<name>` keys of its selectively imported names, its renamed
// items, and its package aliases.  `wholeVia` and `namesVia`, parallel to
// `whole` and `names`, hold the import that makes each one visible, as T0219
// advises adding it.
record ImportSets {
  whole: List[String]
  wholeVia: List[String]
  names: List[String]
  namesVia: List[String]
  renames: List[RenamedImport]
  aliasPkgs: List[String]
  aliasNames: List[String]
}

func importSelectorItems(sel: in ImportSelector): List[ImportItem] {
  match sel {
    case ISGroup(group) -> group
    case ISSingle(one) -> {
      val single: List[ImportItem] = newList()
      single.add(one)
      single
    }
  }
}

func collectImportSets(imports: in List[ImportDecl], importedPackages: in List[ImportedPackage]): ImportSets {
  val whole: List[String] = newList()
  val wholeVia: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  val names: List[String] = newList()
  val namesVia: List[String] = newList()
  val renames: List[RenamedImport] = newList()
  val aliasPkgs: List[String] = newList()
  val aliasNames: List[String] = newList()
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if not imp.isExtern {
      val pkg = dottedPackageName(imp.path)
      match imp.selector {
        case Some(sel) -> {
          val items = importSelectorItems(sel)
          var k = 0
          while k < items.count {
            match items[k].asAlias {
              // A renamed item (`P.{f as g}`, #7564) makes `g`, not `f`,
              // visible bare; `Lyric.AliasRewriter` has already rewritten
              // each use of `g` to `P.f`.  `g` is checked for collisions
              // (T0148).
              case Some(renamed) -> renames.add(
                RenamedImport(local = renamed, pkg = pkg, name = items[k].name, span = items[k].span)
              )
              case None -> {
                names.add(pkg + "|" + items[k].name)
                namesVia.add(importKeyword(imp) + pkg + ".{" + items[k].name + "}")
              }
            }
            k = k + 1
          }
        }
        case None -> match imp.asAlias {
          case Some(alias) -> {
            aliasPkgs.add(pkg)
            aliasNames.add(alias)
          }
          case None -> {
            if not seen.containsKey(pkg) {
              seen.add(pkg, true)
              whole.add(pkg)
              wholeVia.add(importKeyword(imp) + pkg)
            }
          }
        }
      }
    }
    i = i + 1
  }
  // A name listed from a package that re-exports others (`pub use Q`) may be
  // declared by them: `import Std.Collections.{newMap}` lists the `newMap`
  // `Std.CollectionsHost` declares.  The listing makes it visible from each
  // re-exported package too.
  val listedCount = names.count
  var li = 0
  while li < listedCount {
    var bar = -1
    var ci = 0
    while ci < names[li].length and bar < 0 {
      if names[li].substring(ci, 1) == "|" {
        bar = ci
      }
      ci = ci + 1
    }
    if bar > 0 {
      val listedPkg = names[li].substring(0, bar)
      val listedName = names[li].substring(bar + 1)
      for q in reexportClosure(listedPkg, importedPackages) {
        val key = q + "|" + listedName
        if not names.contains(key) {
          names.add(key)
          namesVia.add(namesVia[li])
        }
      }
    }
    li = li + 1
  }
  var w = 0
  while w < whole.count {
    var p = 0
    while p < importedPackages.count {
      if importedPackages[p].name == whole[w] {
        // A whole import reaches what the package re-exports (`pub use`),
        // transitively; its other imports are its own (docs/70 §4.3, D311).
        val deps = importedPackages[p].reexports
        var d = 0
        while d < deps.count {
          if not seen.containsKey(deps[d]) {
            seen.add(deps[d], true)
            whole.add(deps[d])
            wholeVia.add(wholeVia[w])
          }
          d = d + 1
        }
      }
      p = p + 1
    }
    w = w + 1
  }
  ImportSets(
    whole = whole,
    wholeVia = wholeVia,
    names = names,
    namesVia = namesVia,
    renames = renames,
    aliasPkgs = aliasPkgs,
    aliasNames = aliasNames
  )
}

// The packages `pkg` re-exports, directly or through their own re-exports.
func reexportClosure(pkg: in String, importedPackages: in List[ImportedPackage]): List[String] {
  val acc: List[String] = newList()
  val queue: List[String] = newList()
  queue.add(pkg)
  var qi = 0
  while qi < queue.count {
    for ip in importedPackages {
      if ip.name == queue[qi] {
        for r in ip.reexports {
          if r != pkg and not acc.contains(r) {
            acc.add(r)
            queue.add(r)
          }
        }
      }
    }
    qi = qi + 1
  }
  acc
}

// `import ` or, for a re-export, `pub use `.
func importKeyword(imp: in ImportDecl): String {
  if imp.isPubUse {
    "pub use "
  } else {
    "import "
  }
}

// An import as written, for the advice of T0219.
func renderImportDecl(imp: in ImportDecl): String {
  var text = importKeyword(imp)
  if imp.isExtern {
    text = text + "extern "
  }
  text = text + dottedPackageName(imp.path)
  match imp.selector {
    case Some(sel) -> {
      val items = importSelectorItems(sel)
      text = text + ".{"
      var k = 0
      while k < items.count {
        if k > 0 {
          text = text + ", "
        }
        text = text + items[k].name
        match items[k].asAlias {
          case Some(a) -> {
            text = text + " as " + a
          }
          case None -> ()
        }
        k = k + 1
      }
      text = text + "}"
    }
    case None -> ()
  }
  match imp.asAlias {
    case Some(a) -> {
      text = text + " as " + a
    }
    case None -> ()
  }
  text
}

// One file's import rule (docs/70 §4.1): what its own imports make visible,
// each with the import that does it.
func buildFileImportRule(tbl: in SymbolTable, header: in FileHeader, sets: in ImportSets): FileImportRule {
  val wholeVia: Map[String, String] = newMap()
  var w = 0
  while w < sets.whole.count {
    if not wholeVia.containsKey(sets.whole[w]) {
      wholeVia.add(sets.whole[w], sets.wholeVia[w])
    }
    w = w + 1
  }
  val namesVia: Map[String, String] = newMap()
  var n = 0
  while n < sets.names.count {
    if not namesVia.containsKey(sets.names[n]) {
      namesVia.add(sets.names[n], sets.namesVia[n])
    }
    n = n + 1
  }
  val directVia: Map[String, String] = newMap()
  val reachVia: Map[String, String] = newMap()
  val externVia: Map[String, String] = newMap()
  val pending: List[String] = newList()
  val pendingVia: List[String] = newList()
  for imp in header.imports {
    val text = renderImportDecl(imp)
    if imp.isExtern {
      match imp.selector {
        case Some(sel) -> {
          for item in importSelectorItems(sel) {
            val local = match item.asAlias { case Some(a) -> a; case None -> item.name }
            if not externVia.containsKey(local) {
              externVia.add(local, text)
            }
          }
        }
        case None -> ()
      }
    } else {
      val pkg = dottedPackageName(imp.path)
      if not directVia.containsKey(pkg) {
        directVia.add(pkg, text)
        pending.add(pkg)
        pendingVia.add(text)
      }
    }
  }
  // The packages the direct imports' own imports reach, for the qualified
  // references that accept one (`qualifiedPkgReachable`).
  var r = 0
  while r < pending.count {
    val cur = pending[r]
    if not reachVia.containsKey(cur) {
      reachVia.add(cur, pendingVia[r])
      for dep in symTablePackageImportsOf(tbl, cur) {
        pending.add(dep)
        pendingVia.add(pendingVia[r])
      }
    }
    r = r + 1
  }
  FileImportRule(
    path = header.path,
    wholeVia = wholeVia,
    namesVia = namesVia,
    directVia = directVia,
    reachVia = reachVia,
    externVia = externVia
  )
}

// Install the docs/01 §9.2 import rule for the package being checked (#7463):
// a whole import (`import P`) makes every name of `P` visible bare, and so,
// transitively, do the packages `P` itself imports whole (the kernel/host
// re-export idiom); a selective import (`import P.{f, T}`) makes only the
// listed names visible; an aliased import (`import P as Q`) makes none
// visible bare, since they are reached as `Q.f`.
//
// Imports are per file (docs/70 §4.1).  Each file of `files` gets its own
// rule, a name is visible bare in a file only through that file's imports
// (`symTableImportVisible`), and its renames (T0148) and selective imports
// (T0210) are checked against its own imports.  A name a file sees only
// through a sibling file's import is T0219 (`symTableNoteBareUse` and kin).
// A rename that collides with a name a sibling's import brings in stays
// T0148, and an alias bound two ways stays B0012, until the passes that
// read the union's renames and aliases read each file's own (#8690).
// A package with no file table, or of one file, has only the union.
func installImportRule(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  userPkg: in String,
  imports: in List[ImportDecl],
  importedPackages: in List[ImportedPackage],
  fileItems: in List[Item],
  files: in List[FileHeader],
): Unit {
  val u = collectImportSets(imports, importedPackages)
  if files.count <= 1 {
    checkRenamedImports(diag, u.renames, u.names, u.whole, u.aliasPkgs, u.aliasNames, importedPackages, fileItems)
    checkSelectiveImportsDeclared(diag, userPkg, imports, importedPackages)
  } else {
    val rules: List[FileImportRule] = newList()
    val fileDiag: List[Diagnostic] = newList()
    for h in files {
      val fs = collectImportSets(h.imports, importedPackages)
      checkRenamedImports(
        fileDiag,
        fs.renames,
        fs.names,
        fs.whole,
        fs.aliasPkgs,
        fs.aliasNames,
        importedPackages,
        fileItems
      )
      checkSelectiveImportsDeclared(diag, userPkg, h.imports, importedPackages)
      rules.add(buildFileImportRule(tbl, h, fs))
    }
    // A rename whose new name a sibling file's import brings in is still
    // T0148: the alias rewriter and the JVM backend read renames from the
    // union of the files' imports (#8690).
    for d in fileDiag {
      diag.add(d)
    }
    val unionDiag: List[Diagnostic] = newList()
    checkRenamedImports(unionDiag, u.renames, u.names, u.whole, u.aliasPkgs, u.aliasNames, importedPackages, fileItems)
    for d in unionDiag {
      var own = false
      for fd in fileDiag {
        if sameSpan(fd.span, d.span) {
          own = true
        }
      }
      if not own {
        diag.add(
          errorDiagnostic(
            d.code,
            d.message +
              " (through another file's import: within one package a renamed import must not collide with a name any file's imports bring in, #8690)",
            d.span
          )
        )
      }
    }
    symTableSetFileRules(tbl, rules)
  }
  symTableSetImportRule(tbl, userPkg, u.whole, u.names, u.aliasPkgs, u.aliasNames)
}

// Whether `te` is `NativeUserdata`, or `NativePtr[Byte]`, the older spelling of a
// callback's userdata slot.
func isUserdataSlotType(te: in TypeExpr, allowBytePtr: in Bool): Bool {
  match te.kind {
    case TParen(inner) -> isUserdataSlotType(inner, allowBytePtr)
    case TRef(path) -> path.segments[path.segments.count - 1] == "NativeUserdata"
    case TGenericApp(head, args) -> {
      if not allowBytePtr or head.segments[head.segments.count - 1] != "NativePtr" or args.count != 1 {
        return false
      }
      match args[0] {
        case TAType(inner) -> match inner.kind {
          case TRef(ip) -> ip.segments[ip.segments.count - 1] == "Byte"
          case _ -> false
        }
        case TAValue(_) -> false
      }
    }
    case _ -> false
  }
}

// T0181: a function-typed parameter of an `extern func` is a C callback, and a
// Lyric closure reaches C through its userdata slot, so the type must name one:
// a `NativeUserdata` parameter, or a trailing `NativePtr[Byte]` (D189).
func checkExternCallbackSlot(diag: in List[Diagnostic], fname: in String, pname: in String, te: in TypeExpr): Unit {
  match te.kind {
    case TParen(inner) -> checkExternCallbackSlot(diag, fname, pname, inner)
    case TFunction(ps, _) -> {
      var found = false
      var i = 0
      while i < ps.count {
        if isUserdataSlotType(ps[i], false) or (i == ps.count - 1 and isUserdataSlotType(ps[i], true)) {
          found = true
        }
        i = i + 1
      }
      if not found {
        diag.add(
          errorDiagnostic(
            "T0181",
            "extern func '" + fname + "' parameter '" + pname +
              "' is a callback type with no userdata slot: C can call a Lyric closure only through the pointer the API hands back, so mark that parameter NativeUserdata (or end the parameter list with NativePtr[Byte])",
            te.span
          )
        )
      }
    }
    case _ -> ()
  }
}

// The C bindings of a file (D158).  `@library("name")` names the C library
// an `extern func` binds into: P/Invoke on .NET, a foreign-function downcall
// on the JVM, a `-l` link flag on the native target.  The native target
// alone can bind without one (the `lyric_rt` runtime is always linked), so
// elsewhere a missing library is T0149.  A library's argument is one
// non-empty string (T0150), and a library binding's parameters and result
// are the C scalars and pointers every target can pass (T0151).
func checkExternFuncBindings(diag: in List[Diagnostic], items: in List[Item], native: in Bool): Unit {
  for it in items {
    match it.kind {
      case IExternFunc(decl) -> {
        var libCount = 0
        var libOk = true
        for a in it.annotations {
          if a.name.segments.count == 1 and a.name.segments[0] == "library" {
            libCount = libCount + 1
            val one = a.args.count == 1 and
              match a.args[0] {
                case ALiteral(v, _) -> match v { case AVString(x, _) -> x.length > 0; case _ -> false }
                case _ -> false
              }
            if not one {
              libOk = false
              diag.add(
                errorDiagnostic(
                  "T0150",
                  "@library takes one argument, the C library's name as a non-empty string: @library(\"webview\")",
                  a.span
                )
              )
            }
          }
        }
        if libCount > 1 {
          diag.add(errorDiagnostic("T0150", "extern func '" + decl.name + "' names more than one @library", decl.span))
        }
        if libCount == 0 and not native {
          diag.add(
            errorDiagnostic(
              "T0149",
              "extern func '" + decl.name + "' binds the C symbol \"" + decl.symbol +
                "\" but names no library; add @library(\"name\") to bind it on --target dotnet and --target jvm",
              decl.span
            )
          )
        }
        for p in decl.params {
          checkExternCallbackSlot(diag, decl.name, p.name, p.ty)
        }
        // Native lowers the full `extern func` surface (`String`, records);
        // the managed targets marshal only the types every runtime passes
        // the same way, and C callbacks over them (D229).
        if libCount > 0 and libOk and not native {
          for p in decl.params {
            checkCBindingType(diag, decl.name, p.ty, false, false)
          }
          match decl.ret {
            case Some(te) -> checkCBindingType(diag, decl.name, te, true, false)
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
  }
}

// T0151 unless `te` is a type a C binding passes the same way on every
// target: `Int` (int32), `Long` (int64), `Byte` (uint8), `Float` (float,
// binary32 on every backend since D155, #7966), `Double` (double), a
// `NativePtr[T]` (a pointer), or, as a result, `Unit` (void).  A parameter
// may also be `NativeUserdata` (a `void*`) or a C callback (D229): a function
// type whose parameters and result are again these types, which the managed
// backends call through a trampoline.  `inCallback` checks such a callback's
// own parameters and result, where a further function type is rejected.
func checkCBindingType(
  diag: in List[Diagnostic],
  fname: in String,
  te: in TypeExpr,
  isResult: in Bool,
  inCallback: in Bool,
): Unit {
  val ok = match te.kind {
    case TRef(path) -> {
      val n = path.segments[path.segments.count - 1]
      path.segments.count == 1 and
        (
          n == "Int" or n == "Long" or n == "Byte" or n == "Float" or n == "Double" or (isResult and n == "Unit") or
            (not isResult and n == "NativeUserdata")
        )
    }
    case TGenericApp(head, _) -> head.segments.count == 1 and head.segments[0] == "NativePtr"
    case TUnit -> isResult
    case TParen(inner) -> {
      checkCBindingType(diag, fname, inner, isResult, inCallback)
      return
    }
    case TFunction(ps, r) -> {
      if isResult or inCallback {
        false
      } else {
        for cp in ps {
          checkCBindingType(diag, fname, cp, false, true)
        }
        checkCBindingType(diag, fname, r, true, true)
        return
      }
    }
    case _ -> false
  }
  if not ok {
    val what = if inCallback { "a C callback's parameter or result" } else { "this type" }
    diag.add(
      errorDiagnostic(
        "T0151",
        "extern func '" + fname + "': " + what +
          " cannot cross a C binding; use Int, Long, Byte, Float, Double or NativePtr[T]" +
          (
            if isResult {
              ", or Unit for no result"
            } else if inCallback {
              ", or NativeUserdata"
            } else {
              ", NativeUserdata, or a callback over these types"
            }
          ),
        te.span
      )
    )
  }
}

// T0210: a selective import (`import P.{f}` or `import P.{f as g}`) of a
// name `P` does not declare is an error at the import item (#7926), where a
// stale import left behind by a rename in `P` would otherwise surface only at
// a use (T0020), or never.  A name counts as declared when `P` declares an
// item or union/enum case of that name (whatever its visibility; this check
// does not judge access), or when a package `P` imports (at any depth) does,
// because `pub use` re-exports reach a consumer through `P`.  A package the
// checker was not given the source of, and one holding an extern package, a
// fixture, an error item or a destructuring `val` (whose members it cannot
// enumerate here), is never diagnosed.
func checkSelectiveImportsDeclared(
  diag: in List[Diagnostic],
  userPkg: in String,
  imports: in List[ImportDecl],
  importedPackages: in List[ImportedPackage],
): Unit {
  for imp in imports {
    if not imp.isExtern {
      val pkg = dottedPackageName(imp.path)
      if pkg != userPkg and importedPackageKnown(importedPackages, pkg) {
        match imp.selector {
          case Some(sel) -> {
            val items: List[ImportItem] = match sel {
              case ISGroup(group) -> group
              case ISSingle(one) -> {
                val single: List[ImportItem] = newList()
                single.add(one)
                single
              }
            }
            for item in items {
              val visited: List[String] = newList()
              if not packageDeclaresName(importedPackages, pkg, item.name, visited) {
                val near = nearestDeclaredName(importedPackages, pkg, item.name)
                val hint = if near.length > 0 { "; did you mean '" + near + "'?" } else { "" }
                diag.add(
                  errorDiagnostic(
                    "T0210",
                    "package " + pkg + " declares no '" + item.name + "', so it cannot be imported" + hint,
                    item.span
                  )
                )
              }
            }
          }
          case None -> ()
        }
      }
    }
  }
}

func importedPackageKnown(importedPackages: in List[ImportedPackage], pkg: in String): Bool {
  for ip in importedPackages {
    if ip.name == pkg {
      return true
    }
  }
  false
}

func packageDeclaresName(
  importedPackages: in List[ImportedPackage],
  pkg: in String,
  name: in String,
  visited: in List[String],
): Bool {
  for v in visited {
    if v == pkg {
      return false
    }
  }
  visited.add(pkg)
  for ip in importedPackages {
    if ip.name == pkg {
      if itemsMayDeclare(ip.items, name) {
        return true
      }
      for dep in ip.imports {
        if packageDeclaresName(importedPackages, dep, name, visited) {
          return true
        }
      }
    }
  }
  false
}

func itemsMayDeclare(items: in List[Item], name: in String): Bool {
  for it in items {
    match topLevelItemName(it) {
      case Some(n) -> if n == name { return true }
      case None -> ()
    }
    for cn in caseNamesOf(it) {
      if cn == name {
        return true
      }
    }
    val other = match it.kind {
      case IVal(vd) -> match vd.pattern.kind { case PBinding(n, None) -> n == name; case _ -> true }
      case IExternFunc(ed) -> ed.name == name
      case IWire(wd) -> wd.name == name
      case IConfig(cd) -> cd.name == name
      case IAspect(ad) -> ad.name == name
      case IScopeKind(sd) -> sd.name == name
      case IExtern(_) -> true
      case IFixture(_) -> true
      case IError -> true
      case _ -> false
    }
    if other {
      return true
    }
  }
  false
}

// The declared name of `pkg`, or of a package reached through its imports (the
// packages `packageDeclaresName` walks), closest to `name`, or "" when none is
// near enough (edit distance 2, and under half the name's length) to be a typo.
// Ties go to the first declared name.
func nearestDeclaredName(importedPackages: in List[ImportedPackage], pkg: in String, name: in String): String {
  val visited: List[String] = newList()
  val best: List[String] = newList()
  best.add("")
  val bestDist: List[Int] = newList()
  bestDist.add(3)
  nearestDeclaredNameIn(importedPackages, pkg, name, visited, best, bestDist)
  best[0]
}

func nearestDeclaredNameIn(
  importedPackages: in List[ImportedPackage],
  pkg: in String,
  name: in String,
  visited: in List[String],
  best: in List[String],
  bestDist: in List[Int],
): Unit {
  for v in visited {
    if v == pkg {
      return
    }
  }
  visited.add(pkg)
  for ip in importedPackages {
    if ip.name == pkg {
      for it in ip.items {
        val cands: List[String] = caseNamesOf(it)
        match topLevelItemName(it) {
          case Some(n) -> cands.add(n)
          case None -> ()
        }
        for c in cands {
          val d = nameEditDistance(c, name)
          if d < bestDist[0] and d * 2 <= name.length and d > 0 {
            best[0] = c
            bestDist[0] = d
          }
        }
      }
      for dep in ip.imports {
        nearestDeclaredNameIn(importedPackages, dep, name, visited, best, bestDist)
      }
    }
  }
}

func nameEditDistance(a: in String, b: in String): Int {
  val n = a.length
  val m = b.length
  if n == 0 {
    return m
  }
  if m == 0 {
    return n
  }
  var prev: List[Int] = newList()
  var j = 0
  while j <= m {
    prev.add(j)
    j = j + 1
  }
  var i = 1
  while i <= n {
    val cur: List[Int] = newList()
    cur.add(i)
    var k = 1
    while k <= m {
      val cost = if a.substring(i - 1, 1) == b.substring(k - 1, 1) { 0 } else { 1 }
      var best = prev[k] + 1
      if cur[k - 1] + 1 < best {
        best = cur[k - 1] + 1
      }
      if prev[k - 1] + cost < best {
        best = prev[k - 1] + cost
      }
      cur.add(best)
      k = k + 1
    }
    prev = cur
    i = i + 1
  }
  prev[m]
}

// A renamed selective import: `local` is the bare name for `pkg.name`.
record RenamedImport {
  local: String
  pkg: String
  name: String
  span: Span
}

// T0148: a renamed import's bare name must not also be a declaration (or
// a union or enum case) of this package, another import's bare name (a
// listed union's or enum's cases included), a public name (or union or
// enum case) of a package imported whole, a package alias, or the head of
// an imported package's path; otherwise one spelling would mean two
// things (#7564).  The alias and path-head checks matter because the
// alias rewriter treats `g.member` as a use of the rename `g`, so an
// unreported collision would silently send `g.member` to the renamed item
// (#7928).
func checkRenamedImports(
  diag: in List[Diagnostic],
  renames: in List[RenamedImport],
  selected: in List[String],
  whole: in List[String],
  aliasPkgs: in List[String],
  aliasNames: in List[String],
  importedPackages: in List[ImportedPackage],
  fileItems: in List[Item],
): Unit {
  val heads: List[String] = newList()
  for wp in whole {
    heads.add(pathHead(wp))
  }
  for ap in aliasPkgs {
    heads.add(pathHead(ap))
  }
  for sel in selected {
    val bar = indexOfRaw(sel, "|")
    if bar > 0 {
      heads.add(pathHead(sel.substring(0, bar)))
    }
  }
  for rn in renames {
    heads.add(pathHead(rn.pkg))
  }
  var r = 0
  while r < renames.count {
    val ren = renames[r]
    val target = ren.pkg + "." + ren.name
    var clash = ""
    for it in fileItems {
      match topLevelItemName(it) {
        case Some(n) -> if n == ren.local and clash.length == 0 {
          clash = "this package declares its own '" + ren.local + "'"
        }
        case None -> ()
      }
      for cn in caseNamesOf(it) {
        if cn == ren.local and clash.length == 0 {
          clash = "this package declares the case '" + ren.local + "'"
        }
      }
    }
    for sel in selected {
      val bar = indexOfRaw(sel, "|")
      if bar > 0 and sel.substring(bar + 1) == ren.local and clash.length == 0 {
        clash = "'" + ren.local + "' is also imported from " + sel.substring(0, bar)
      }
      // A listed union or enum brings its cases into bare scope too
      // (`import P.{Shape}` makes `Circle` bare, #7967).
      if bar > 0 and clash.length == 0 {
        val selPkg = sel.substring(0, bar)
        val selName = sel.substring(bar + 1)
        for ip in importedPackages {
          if ip.name == selPkg {
            for it in ip.items {
              val named = match topLevelItemName(it) { case Some(n) -> n == selName; case None -> false }
              if named and clash.length == 0 {
                for cn in caseNamesOf(it) {
                  if cn == ren.local and clash.length == 0 {
                    clash = "'" + ren.local + "' is also a case of " + selPkg + "." + selName + ", imported from " + selPkg
                  }
                }
              }
            }
          }
        }
      }
    }
    var o = 0
    while o < renames.count {
      if o != r and renames[o].local == ren.local and clash.length == 0 {
        clash = "'" + ren.local + "' also renames " + renames[o].pkg + "." + renames[o].name
      }
      o = o + 1
    }
    var a = 0
    while a < aliasNames.count {
      if aliasNames[a] == ren.local and clash.length == 0 {
        clash = "'" + ren.local + "' is also the alias of " + aliasPkgs[a]
      }
      a = a + 1
    }
    for h in heads {
      if h == ren.local and clash.length == 0 {
        clash = "'" + ren.local + "' also begins an imported package's path"
      }
    }
    for wp in whole {
      for ip in importedPackages {
        if ip.name == wp and clash.length == 0 {
          for it in ip.items {
            val isPub = match it.visibility { case Some(_) -> true; case None -> false }
            match topLevelItemName(it) {
              case Some(n) -> if isPub and n == ren.local and clash.length == 0 {
                clash = wp + ", imported whole, also declares '" + ren.local + "'"
              }
              case None -> ()
            }
            if isPub and clash.length == 0 {
              for cn in caseNamesOf(it) {
                if cn == ren.local and clash.length == 0 {
                  clash = wp + ", imported whole, also has the case '" + ren.local + "'"
                }
              }
            }
          }
        }
      }
    }
    if clash.length > 0 {
      diag.add(
        errorDiagnostic(
          "T0148",
          "the renamed import '" + ren.local + "' (for " + target + ") is ambiguous: " + clash + "; choose another name",
          ren.span
        )
      )
    }
    r = r + 1
  }
}

// The first segment of a dotted package path.
func pathHead(path: in String): String {
  val dot = indexOfRaw(path, ".")
  return if dot > 0 { path.substring(0, dot) } else { path }
}

// The case names a union or enum item makes visible bare, for the rename
// collision check.
func caseNamesOf(it: in Item): List[String] {
  val acc: List[String] = newList()
  match it.kind {
    case IUnion(ud) -> {
      for c in ud.cases {
        acc.add(c.name)
      }
    }
    case IEnum(ed) -> {
      for c in ed.cases {
        acc.add(c.name)
      }
    }
    case _ -> ()
  }
  return acc
}

// The name a top-level item declares, for the rename collision check.
func topLevelItemName(it: in Item): Option[String] {
  return match it.kind {
    case IFunc(fd) -> Some(value = fd.name)
    case IRecord(rd) -> Some(value = rd.name)
    case IExposedRec(rd) -> Some(value = rd.name)
    case IUnion(ud) -> Some(value = ud.name)
    case IEnum(ed) -> Some(value = ed.name)
    case IOpaque(od) -> Some(value = od.name)
    case IProtected(pd) -> Some(value = pd.name)
    case IInterface(idl) -> Some(value = idl.name)
    case IConst(cd) -> Some(value = cd.name)
    case ITypeAlias(ta) -> Some(value = ta.name)
    case IDistinctType(dt) -> Some(value = dt.name)
    case IExternType(et) -> Some(value = et.name)
    case _ -> None
  }
}

// Register external types from `import extern` declarations (D105, Phase 2a).
// For each `import extern Namespace.{ Type as Alias }`, registers `Alias` as
// a symbol of kind `DKExternType` with a synthetic ExternTypeDecl carrying the
// external FQN. This allows auto-FFI to resolve method calls on imported
// external types just as it does for `extern type` declarations.
// Each is identified by its external FQN (`externTypeDefPath`), as an
// `extern type` is, so repeated imports of one external type share one
// SymbolId.
// Public (`pub use extern`) and private (`import extern`) imports are both
// supported with correct visibility semantics.
pub func registerExternalImports(tbl: in SymbolTable, diag: in List[Diagnostic], imports: in List[ImportDecl]): Unit {
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if imp.isExtern {
      val baseNamespace = dottedPackageName(imp.path)
      match imp.selector {
        case Some(ISGroup(items)) -> {
          var j = 0
          while j < items.count {
            val item = items[j]
            val externalFqn = if baseNamespace.length > 0 { baseNamespace + "." + item.name } else { item.name }
            val symbolName = match item.asAlias { case Some(aliasName) -> aliasName; case None -> item.name }
            // Deduplicate by external FQN like regular `extern type`.
            val tid = symTableInternDefPath(tbl, externTypeDefPath(externalFqn))
            // Create a synthetic ExternTypeDecl with no generics (external types
            // are monomorphic from the import perspective; generics are resolved
            // through auto-FFI metadata lookup).  `clrNameQuoted` is a formatter-
            // only concern (#5472) and irrelevant here: an `import extern`
            // statement, not an `extern type` item, is what actually appears in
            // `SourceFile.items` and gets formatted.
            val syntheticDecl = ExternTypeDecl(
              name = symbolName,
              generics = None,
              clrName = externalFqn,
              clrNameQuoted = true,
              arityAppended = false,
              span = imp.span
            )
            val vis = if imp.isPubUse { Some(value = VisPub(span = imp.span)) } else { None }
            val _ = addSym(tbl, diag, false, "", symbolName, DKExternType(id = tid, decl = syntheticDecl), vis, imp.span)
            j = j + 1
          }
        }
        case Some(ISSingle(item)) -> {
          val externalFqn = if baseNamespace.length > 0 { baseNamespace + "." + item.name } else { item.name }
          val symbolName = match item.asAlias { case Some(aliasName) -> aliasName; case None -> item.name }
          // Deduplicate by external FQN like regular `extern type`.
          val tid = symTableInternDefPath(tbl, externTypeDefPath(externalFqn))
          // Create a synthetic ExternTypeDecl.
          val syntheticDecl = ExternTypeDecl(
            name = symbolName,
            generics = None,
            clrName = externalFqn,
            clrNameQuoted = true,
            arityAppended = false,
            span = imp.span
          )
          val vis = if imp.isPubUse { Some(value = VisPub(span = imp.span)) } else { None }
          val _ = addSym(tbl, diag, false, "", symbolName, DKExternType(id = tid, decl = syntheticDecl), vis, imp.span)
        }
        case None -> {
          val externalFqn = dottedPackageName(imp.path)
          val typeName = imp.path.segments[imp.path.segments.count - 1]
          val symbolName = unwrapOr(imp.asAlias, typeName)
          // Deduplicate by external FQN like regular `extern type`.
          val tid = symTableInternDefPath(tbl, externTypeDefPath(externalFqn))
          // Create a synthetic ExternTypeDecl.
          val syntheticDecl = ExternTypeDecl(
            name = symbolName,
            generics = None,
            clrName = externalFqn,
            clrNameQuoted = true,
            arityAppended = false,
            span = imp.span
          )
          val vis = if imp.isPubUse { Some(value = VisPub(span = imp.span)) } else { None }
          val _ = addSym(tbl, diag, false, "", symbolName, DKExternType(id = tid, decl = syntheticDecl), vis, imp.span)
        }
      }
    }
    i = i + 1
  }
}

// Flatten the items of every imported package into one list, in package then
// declaration order.  Both bridges feed the result to `deriveFileWithImports`
// so a `@derive(Ord)` field typed as a cross-package distinct type resolves
// through its `.value` projection chain instead of miscompiling to a reference
// comparison (#3287).
pub func flattenImportedItems(pkgs: in List[ImportedPackage]): List[Item] {
  val items: List[Item] = newList()
  var i = 0
  while i < pkgs.count {
    var j = 0
    while j < pkgs[i].items.count {
      items.add(pkgs[i].items[j])
      j = j + 1
    }
    i = i + 1
  }
  items
}

// Scope-aware type check.  Imported items are supplied grouped by their
// declaring package so each package's signatures resolve against its own
// declarations (and its imports), instead of one flat table where the
// last-registered symbol of a given simple name wins every reference —
// including references inside other packages' signatures.
pub func checkWithImportedPackages(file: in SourceFile, importedPackages: in List[ImportedPackage]): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, false, SMSUnchecked, newMap(), newList())
}

/// `checkWithImportedPackages` for a build whose backend bridge can say how the
/// host types behind the `extern type`s iterate (D302): `externIter` maps an
/// `extern type`'s `clrName` to the element type its host protocol yields and
/// `resolver` (zero or one) answers for the types it lacks, which a `for` over
/// one needs to type its loop variable.  `native` is
/// `checkWithImportedPackagesForNative`'s flag.
pub func checkWithImportedPackagesExternIter(
  file: in SourceFile,
  importedPackages: in List[ImportedPackage],
  native: in Bool,
  externIter: in Map[String, ExternIterInfo],
  resolver: in List[ExternIterResolver],
): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, native, SMSUnchecked, externIter, resolver)
}

/// `checkWithImportedPackages` for a `--target native` build: the file may
/// also use the native-only FFI intrinsics (docs/01 §11.6) — the
/// `NativeWeak[T]` type and the `nativeAddrOf`, `NativeWeak` and `upgrade`
/// calls — which no other target can lower.  `NativePtr[T]` and
/// `nativeNullPtr()` exist on every target (D158).
pub func checkWithImportedPackagesForNative(
  file: in SourceFile, importedPackages: in List[ImportedPackage]
): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, true, SMSUnchecked, newMap(), newList())
}

/// `checkWithImportedPackages` / `checkWithImportedPackagesForNative` for a
/// target whose `String` method surface is known (#7204): a method call on a
/// `String` that the target cannot lower is T0113 at check time instead of a
/// codegen panic or a runtime failure.
pub func checkWithImportedPackagesForTarget(
  file: in SourceFile,
  importedPackages: in List[ImportedPackage],
  nativeIntrinsics: in Bool,
  stringSurface: in StringMethodSurface,
): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, nativeIntrinsics, stringSurface, newMap(), newList())
}

/// `checkWithImportedPackagesForTarget` for a backend bridge that can say how
/// the host types behind `extern type`s iterate (D302): `externIter` and
/// `resolver` are `checkWithImportedPackagesExternIter`'s.
pub func checkWithImportedPackagesForTargetIter(
  file: in SourceFile,
  importedPackages: in List[ImportedPackage],
  nativeIntrinsics: in Bool,
  stringSurface: in StringMethodSurface,
  externIter: in Map[String, ExternIterInfo],
  resolver: in List[ExternIterResolver],
): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, nativeIntrinsics, stringSurface, externIter, resolver)
}

// The FFI intrinsic types.  Every backend lowers them by name, so they are
// declared here only to give their uses a type; the `clrName`s name no CLR
// or JVM class and are never resolved.  `NativePtr[T]` is the raw pointer of
// a C binding (`extern func`, D158) on every target, and `NativeUserdata`
// marks the userdata slot of a C callback type on every target (D229);
// `NativeWeak[T]` exists only on the native target, which alone has ARC.
val ffiIntrinsicTypesSource: String = "package Lyric.NativeIntrinsics\n" + "extern type NativePtr[T] = \"lyric.native.NativePtr\"\n" + "extern type NativeUserdata = \"lyric.native.NativeUserdata\"\n"

val nativeIntrinsicTypesSource: String = ffiIntrinsicTypesSource + "extern type NativeWeak[T] = \"lyric.native.NativeWeak\"\n"

// Register the FFI intrinsic types with no declaring package, so every file
// sees them bare with no import, as codegen does.  They are registered
// before any other package, so a type of the same name declared anywhere
// else shadows them.  `native` adds the native-only `NativeWeak[T]`.
func registerNativeIntrinsicTypes(tbl: in SymbolTable, native: in Bool): Unit {
  val pr = parse(if native then nativeIntrinsicTypesSource else ffiIntrinsicTypesSource)
  val scratch: List[Diagnostic] = newList()
  for it in pr.file.items {
    registerItem(tbl, scratch, true, "", it)
    match it.kind {
      case IExternType(decl) -> match symbolTypeIdOpt(tbl.symbols[tbl.symbols.count - 1]) {
        case Some(tid) -> tbl.nativeIntrinsicTypes.add(decl.name, tid)
        case None -> ()
      }
      case _ -> ()
    }
  }
}

// Contract-surface variant used when re-type-checking a *synthesised*
// restored-package source (`Lyric.RestoredPackages.synthesiseArtifact`).
// The synthesised file flattens one package's public decls plus a partial
// sibling-type preamble; sibling types whose names collide with this
// package's enum/union case names are deliberately dropped from the
// preamble (#2514), so preamble record fields may reference types that are
// absent from the flattened file.  Declaration-position validation (#1228)
// would report those as unknown — correct for user code, noise here — so
// this entry point skips the T4 decl pass while keeping every other check.
pub func checkContractSurface(file: in SourceFile): CheckResult {
  val empty: List[ImportedPackage] = newList()
  checkWithImportedPackagesCore(file, empty, false, false, SMSUnchecked, newMap(), newList())
}

// T0199: a string-literal template of `format1`-`format4` is checked against
// the placeholder grammar `Std.String.formatArgs` enforces at run time (the
// same scanner, `formatTemplateProblem`), so a malformed brace or a
// placeholder beyond the call's arguments fails the build instead (#7983).
func checkFormatTemplate(diag: in List[Diagnostic], calleeName: in String, args: in List[CallArg]): Unit {
  if args.count == 0 {
    return
  }
  match formatBuiltinArity(calleeName) {
    case None -> ()
    case Some(arity) -> {
      if args.count != arity + 1 {
        return
      }
      val first = callArgExpr(args[0])
      match first.kind {
        case ELiteral(lit) -> match lit {
          case LString(text) -> {
            val problem = formatTemplateProblem(text, arity)
            if problem.length > 0 {
              diag.add(errorDiagnostic("T0199", "invalid " + calleeName + " template: " + problem, first.span))
            }
          }
          case _ -> ()
        }
        case _ -> ()
      }
    }
  }
}

// Y0009: a package is either `@pure` or `@io` (docs/01 §9.4).  The layer
// check reports this only when the project has a `[layers]` table, and the
// package merge reports files of one package that disagree; a single file
// carrying both is reported here, whatever the manifest says (#8244).
func reportConflictingClassification(diag: in List[Diagnostic], file: in SourceFile): Unit {
  var first = ""
  for a in file.fileAnnotations {
    val n = modulePathJoin(a.name.segments)
    if n == "pure" or n == "io" {
      if first == "" {
        first = n
      } else if first != n {
        diag.add(errorDiagnostic("Y0009", "a package is either @pure or @io, not both", a.span))
        return
      }
    }
  }
}

// `packages` without the package `own`.  A project build hands the checker
// every project package as an import, the one being checked included
// (#7583); a package is not its own import, and registering its declarations
// a second time, as imported, would give each of its types a second symbol
// with the same SymbolId (docs/70 §4.2) that first-match scans could pick.
func withoutOwnPackage(packages: in List[ImportedPackage], own: in String): List[ImportedPackage] {
  val kept: List[ImportedPackage] = newList()
  for ip in packages {
    if own.length == 0 or ip.name != own {
      kept.add(ip)
    }
  }
  kept
}

func checkWithImportedPackagesCore(
  file0: in SourceFile,
  allImportedPackages: in List[ImportedPackage],
  validateDecls: in Bool,
  nativeIntrinsics: in Bool,
  stringSurface: in StringMethodSurface,
  externIter: in Map[String, ExternIterInfo],
  resolver: in List[ExternIterResolver],
): CheckResult {
  val importedPackages = withoutOwnPackage(allImportedPackages, dottedPackageName(file0.packageDecl.path))
  val diag: List[Diagnostic] = newList()
  val tbl = newSymbolTable()
  tbl.stringSurface.add(stringSurface)
  for r in resolver {
    tbl.externIterResolver.add(r)
  }
  for iterKey in mapKeys(externIter) {
    match mapGet(externIter, iterKey) {
      case Some(info) -> tbl.externIterElems.add(iterKey, info)
      case None -> ()
    }
  }
  for fa in file0.fileAnnotations {
    if fa.name.segments.count == 1 and fa.name.segments[0] == contractSourceAnnotationName() {
      tbl.contractSourceFile.add(true)
    }
  }
  registerNativeIntrinsicTypes(tbl, nativeIntrinsics)

  // A destructuring module-level `val` binds each of its names (#7763).  The
  // compile pipeline has already desugared the file it passes here (so its
  // backends see the same items), making this a no-op there; other callers
  // (the language server, direct checks) get the same bindings and T0144.
  val mvRes = desugarModuleValPatterns(file0)
  val file = mvRes.file
  for d in mvRes.diagnostics {
    diag.add(d)
  }

  val userPkg = dottedPackageName(file.packageDecl.path)
  tbl.arrayLenPkg.add(userPkg)
  val userImports = collectImportNames(file.imports)
  reportConflictingClassification(diag, file)

  // T1: register imported items first (shadow without error), tagging each
  // symbol with its declaring package so scoped resolution can prefer it.
  var p = 0
  while p < importedPackages.count {
    val ip = importedPackages[p]
    symTableRegisterPackageReexports(tbl, ip.name, ip.reexports)
    // T0144 in another package is that package's own build error.
    val ipDiag: List[Diagnostic] = newList()
    val ipItems = desugarModuleValItems(ip.items, ipDiag)
    var ii = 0
    while ii < ipItems.count {
      registerItem(tbl, diag, true, ip.name, ipItems[ii])
      ii = ii + 1
    }
    p = p + 1
  }
  var j = 0
  while j < file.items.count {
    registerItem(tbl, diag, false, userPkg, file.items[j])
    j = j + 1
  }

  // T1.5: register external imports from `import extern` declarations (D105, Phase 2a).
  // This must happen after T1 so regular Lyric types are already in scope for
  // shadowing, and before symTableSetScope so the scope is computed afterward.
  registerExternalImports(tbl, diag, file.imports)

  // From here on, resolve under the user package's scope by default: the
  // user's own declarations win, then its imports, then last-registered.
  symTableSetScope(tbl, userPkg, userImports)
  val resolveDeps: List[DepPackage] = newList()
  for ip in importedPackages {
    resolveDeps.add(DepPackage(name = ip.name, items = ip.items, reexports = ip.reexports))
  }
  tbl.resolveCtx.add(buildResolverContext(resolveDeps, file, tbl.interner))
  if getVarOrDefault("LYRIC_RESOLVE_DIFF", "") == "1" {
    tbl.diffOn.add(true)
  }

  // T2.5: validate range subtypes.
  var k = 0
  while k < file.items.count {
    match file.items[k].kind {
      case IDistinctType(decl) -> checkDistinctType(tbl, diag, decl)
      case _ -> {
      }
    }
    k = k + 1
  }

  // T3: resolve signatures (imported + user).
  //
  // Each imported package's signatures and impls resolve under that package's
  // own scope.  An error there means the dependency's surface does not
  // resolve (a missing dependency, or a declaration naming a type nothing
  // loaded declares), so it is reported once per package as T0211 instead of
  // leaving `TyError` in the signature for codegen to meet (docs/70 §5.3).
  // Each package's sigs resolve under its own scope so a type ref binds to the
  // declaring package's type, not a same-named sibling's (the RegexError case).
  val sigs: Map[String, ResolvedSignature] = newMap()
  // Interface-conformance registration resolves impl iface/target names purely
  // to key the subtyping relation, so its diagnostics are discarded (genuine
  // unresolved-type errors surface via sig resolution / checkImplConformance).
  val implDiag: List[Diagnostic] = newList()
  var sp = 0
  while sp < importedPackages.count {
    val ip2 = importedPackages[sp]
    // Tier 2 sees the package's OWN declared imports, so a type it imports from
    // a sibling beats an unrelated same-named export elsewhere (#2282).
    symTableSetScope(tbl, ip2.name, ip2.imports)
    // #6689: remember this package's own imports so a LATER cross-package
    // field-type resolution (`collectCtorFields`, run during some other
    // package's body-check) can temporarily re-enter this exact scope
    // instead of resolving under whichever package is calling in.
    symTableRegisterPackageImports(tbl, ip2.name, ip2.imports)
    val pkgDiag: List[Diagnostic] = newList()
    addSigsFromItems(tbl, pkgDiag, sigs, ip2.items, true, ip2.name)
    registerImplsFromItems(tbl, newGenericContext(), pkgDiag, ip2.items)
    addMethodSigsFromItems(tbl, ip2.items, ip2.name)
    reportDependencySurfaceError(diag, ip2.name, exportedSurfaceDiagnostics(ip2.items, pkgDiag), file.packageDecl.span)
    sp = sp + 1
  }

  // User signatures + bodies resolve under the user package's scope, and
  // its bare names under the file's import rule.
  symTableSetScope(tbl, userPkg, userImports)
  symTableRegisterPackageImports(tbl, userPkg, userImports)
  installImportRule(tbl, diag, userPkg, file.imports, importedPackages, file.items, file.files)
  checkExternFuncBindings(diag, file.items, nativeIntrinsics)
  addSigsFromItems(tbl, diag, sigs, file.items, false, userPkg)
  checkExportedSignatureVisibility(userPkg, file.items, diag)
  registerImplsFromItems(tbl, newGenericContext(), implDiag, file.items)
  addMethodSigsFromItems(tbl, file.items, userPkg)

  // T4: validate declaration-position type references (#1228) so an unknown
  // type in a record/union/interface/opaque/protected/alias/val declaration
  // errors at the declaration instead of silently degrading to Object.
  // Skipped for synthesised contract-surface checks (see checkContractSurface).
  if validateDecls {
    checkDeclTypeRefs(tbl, diag, file.items)
  }

  checkReceiverModes(diag, file.items)

  // T5: check user function bodies.
  var m = 0
  while m < file.items.count {
    // Each item is checked in the scope of the file it is written in
    // (docs/70 §4.1); a synthesised item, in the package union.
    symTableEnterSpanFile(tbl, file.items[m].span)
    match file.items[m].kind {
      case IFunc(decl) -> {
        val noExtraLocals: List[LocalBinding] = newList()
        val arityKey = decl.name + "/" + toString(decl.params.count)
        match mapGet(sigs, arityKey) {
          case Some(sig) -> checkFunctionBody(tbl, sigs, diag, decl, sig, noExtraLocals, noExtraLocals, false, TyError)
          case None -> match mapGet(sigs, decl.name) {
            case Some(sig) -> checkFunctionBody(
              tbl,
              sigs,
              diag,
              decl,
              sig,
              noExtraLocals,
              noExtraLocals,
              false,
              TyError
            )
            case None -> {
            }
          }
        }
      }
      case IImpl(decl) -> {
        checkImplGenericTarget(diag, decl)
        checkImplConformance(tbl, diag, decl)
        checkImplOnProtected(tbl, diag, decl, file.items)
        checkImplMethodNameConflicts(tbl, diag, decl, file.items)
        checkSameArityMethods(diag, "impl " + implIfaceName(decl), implMethodHeads(decl.members))
        checkImplMemberBodies(tbl, sigs, diag, decl)
      }
      case IInterface(decl) -> checkInterfaceContracts(tbl, sigs, diag, decl)
      case IProtected(decl) -> checkProtectedMemberBodies(tbl, sigs, diag, decl)
      case IRecord(decl) -> checkRecordMemberBodies(tbl, sigs, diag, decl)
      case IExposedRec(decl) -> checkRecordMemberBodies(tbl, sigs, diag, decl)
      case IOpaque(decl) -> checkOpaqueInvariants(tbl, sigs, diag, decl)
      case IConfig(decl) -> checkConfigBlock(diag, decl)
      case IAspect(decl) -> checkAspectConfigRanges(diag, decl)
      case ITest(decl) -> checkTestBody(tbl, sigs, diag, userPkg, decl)
      case _ -> {
      }
    }
    // A contract surface re-checks another package's signatures without that
    // package's imports; its initialisers were checked when it was built.
    if validateDecls {
      checkItemDeclaredInits(tbl, sigs, diag, file.items[m])
    }
    m = m + 1
  }
  symTableEnterFile(tbl, -1)

  // T6: FFI-boundary lint (W0006).  A public function must not expose an
  // IMPORTED nested CLR extern type (clrName containing `+`, e.g.
  // `JsonElement+ArrayEnumerator`) in its signature: those are BCL
  // implementation-detail structs whose FFI boundary is meant to stay in
  // `_kernel/` (a kernel file declares the extern type locally — not imported —
  // and is therefore exempt).  Leaking one pushes the BCL type into every
  // consumer's emitted IL (#3943).  Wrap it in an opaque Lyric type instead.
  checkExternBoundaryLeaks(tbl, diag, file.items)

  // T7: `old(...)` only inside `ensures:` (T0080, #7731).
  checkOldPlacement(diag, file)
  recordModuleValTypes(tbl, sigs, diag, file.items)
  recordMutableModuleVals(tbl, sigs, file.items)
  // The uses of each open local binding fix its annotation (#7788).
  resolveOpenBindingSites(tbl)
  reportUnspellableArrayCopies(tbl, diag)
  // A `?` operand whose success type nothing fixed (#8181).
  collectPropagateFallbacks(tbl)
  for w in symTableSiblingImportErrors(tbl) {
    diag.add(w)
  }

  for dd in tbl.diffLog {
    diag.add(dd)
  }
  CheckResult(file = file, symbols = tbl, sigs = sigs, diagnostics = diag)
}

// Every candidate type name `checkExternLeakType` should inspect within
// `te`: the outer name for a plain reference, the element name unwrapped
// through `slice[T]` / `T?` / `(T)`, and — for a generic instantiation like
// `Option[JsonArrayEnumerator]` — both the head name and every type
// argument, recursively, so a leak nested inside a generic wrapper is still
// caught rather than silently passing through the outer `Option` (#3964).
func collectExternLeakTypeNames(te: in TypeExpr, names: in List[String]): Unit {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count > 0 {
        names.add(path.segments[path.segments.count - 1])
      }
    }
    case TNullable(inner) -> collectExternLeakTypeNames(inner, names)
    case TSlice(element) -> collectExternLeakTypeNames(element, names)
    case TParen(inner) -> collectExternLeakTypeNames(inner, names)
    case TGenericApp(head, args) -> {
      if head.segments.count > 0 {
        names.add(head.segments[head.segments.count - 1])
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(ty) -> collectExternLeakTypeNames(ty, names)
          case TAValue(_) -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
}

// Emit W0006 if `name` resolves to an imported nested extern type.
func checkExternLeakType(
  tbl: in SymbolTable, diag: in List[Diagnostic], name: in String, sp: in Span, fnName: in String
): Unit {
  if name.length == 0 {
    return
  }
  match symTableTryFindOne(tbl, name) {
    case None -> {
    }
    case Some(sym) -> {
      match sym.kind {
        case DKExternType(_, d) -> {
          if sym.isImported and contains(d.clrName, "+") {
            diag.add(
              warningDiagnostic(
                "W0006",
                "public function '" + fnName + "' exposes imported nested extern type '" + name + "' (" + d.clrName +
                  ") in its signature; wrap it in an opaque Lyric type so the FFI boundary stays in _kernel/",
                sp
              )
            )
          }
        }
        case _ -> {
        }
      }
    }
  }
}

// Check every name reachable from `te` (including nested generic type
// arguments — see `collectExternLeakTypeNames`) for an extern-boundary leak.
func checkExternLeakTypeExpr(tbl: in SymbolTable, diag: in List[Diagnostic], te: in TypeExpr, fnName: in String): Unit {
  val names: List[String] = newList()
  collectExternLeakTypeNames(te, names)
  var i = 0
  while i < names.count {
    checkExternLeakType(tbl, diag, names[i], te.span, fnName)
    i = i + 1
  }
}

func isPubFunctionDecl(fn: in FunctionDecl): Bool {
  match fn.visibility {
    case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
    case None -> false
  }
}

// Check every param / return type of `decl` for a leaked imported nested
// extern type.  Shared by top-level `IFunc` and `impl` block `IMplFunc`
// methods (#3961), but the two callers gate differently: an `IFunc` is only
// checked when `pub` (see `isPubFunctionDecl`), while every `IMplFunc` is
// always checked — per `docs/grammar.ebnf`'s `ImplMember` production, an
// impl-block method is always a bare `FunctionDecl` with no `pub`/`internal`
// prefix (`parseImplMemberOpt` has no visibility-keyword arm at all), so
// `fn.visibility` is unconditionally `None` and can never gate anything.
// An impl method's reachability instead follows its conformed interface /
// target type, which are outside the local, per-item scope this pass
// works in; treating every impl method as checkable is the conservative
// (over- rather than under-warn) choice for a signature-leak lint.
func checkExternBoundaryLeaksFunc(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in FunctionDecl): Unit {
  var p = 0
  while p < decl.params.count {
    checkExternLeakTypeExpr(tbl, diag, decl.params[p].ty, decl.name)
    p = p + 1
  }
  match decl.ret {
    case Some(rt) -> checkExternLeakTypeExpr(tbl, diag, rt, decl.name)
    case None -> {
    }
  }
}

func checkExternBoundaryLeaks(tbl: in SymbolTable, diag: in List[Diagnostic], items: in List[Item]): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        if isPubFunctionDecl(decl) {
          checkExternBoundaryLeaksFunc(tbl, diag, decl)
        }
      }
      case IImpl(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> checkExternBoundaryLeaksFunc(tbl, diag, fn)
            case _ -> {
            }
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Flat-imports compatibility shim.  Wraps every imported item into one
// nameless package, which leaves every imported symbol with an empty
// `originPackage`: scoped resolution's tier-1/tier-2 preferences never match,
// so lookup falls through to last-registered-wins — identical to the
// behaviour before scoped resolution existed.  Callers that can group their
// imports by package (the MSIL / JVM bridges) should call
// `checkWithImportedPackages` directly to get the collision fix.
pub func checkWithImports(file: in SourceFile, importedItems: in List[Item]): CheckResult {
  val packages: List[ImportedPackage] = newList()
  val noImports: List[String] = newList()
  packages.add(ImportedPackage(name = "", items = importedItems, imports = noImports, wholeImports = noImports))
  checkWithImportedPackages(file, packages)
}

pub func check(file: in SourceFile): CheckResult {
  val empty: List[ImportedPackage] = newList()
  checkWithImportedPackages(file, empty)
}
