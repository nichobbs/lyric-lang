//! typechecker_checker.l — public entry point of the type checker.
//! Mirrors compiler/src/Lyric.TypeChecker/Checker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Std.String
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Check result.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record CheckResult {
  file: SourceFile
  symbols: SymbolTable
  sigs: Map[String, ResolvedSignature]
  diagnostics: List[Diagnostic]
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Monotonic type-id source (boxed via List length).
  // ─────────────────────────────────────────────────────────────────────────────
}

pub record TypeIdCounter {
  ticks: List[Int]
}

func newTypeIdCounter(): TypeIdCounter {
  val ticks: List[Int] = newList()
  TypeIdCounter(ticks = ticks)
}

func freshTypeId(ctr: in TypeIdCounter): TypeId {
  ctr.ticks.add(0)
  TypeId(id = ctr.ticks.count)
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
func caseNameExistsForParent(tbl: in SymbolTable, name: in String, parentId: in TypeId): Bool {
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if sym.name == name and not sym.isImported {
      val sameParent = match sym.kind {
        case DKUnionCase(pid, _) -> typeIdEq(pid, parentId)
        case DKEnumCase(pid, _) -> typeIdEq(pid, parentId)
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
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  result
}

// The `TypeId` already assigned to an extern type with CLR target `clrName`,
// if any — so repeat registrations of the same extern type share one canonical
// id (see the `IExternType` arm of `registerItem`, #2394).
// O(N) per extern-type registration — negligible while extern types are rare (dozens at most);
// a clrNameToTypeId side-table could reduce this to O(1) if it becomes measurable.
func findExternTypeIdByClr(tbl: in SymbolTable, clrName: in String): Option[TypeId] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKExternType(id, d) -> if d.clrName == clrName { return Some(value = id) }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
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
  tbl: in SymbolTable,
  ctr: in TypeIdCounter,
  diag: in List[Diagnostic],
  isImported: in Bool,
  originPkg: in String,
  it: in Item,
): Unit {
  val vis = it.visibility
  val span = it.span
  match it.kind {
    case IRecord(decl) -> {
      val tid = freshTypeId(ctr)
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
      val tid = freshTypeId(ctr)
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
      val tid = freshTypeId(ctr)
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
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKEnum(id = tid, decl = decl), vis, span)
      var i = 0
      while i < decl.cases.count {
        val c = decl.cases[i]
        val _ = addSym(tbl, diag, isImported, originPkg, c.name, DKEnumCase(parentId = tid, ec = c), vis, c.span)
        i = i + 1
      }
    }
    case IOpaque(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKOpaque(id = tid, decl = decl), vis, span)
    }
    case IProtected(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKProtected(id = tid, decl = decl), vis, span)
    }
    case IDistinctType(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKDistinctType(id = tid, decl = decl), vis, span)
    }
    case ITypeAlias(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKTypeAlias(decl = decl), vis, span)
    }
    case IInterface(decl) -> {
      val tid = freshTypeId(ctr)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKInterface(id = tid, decl = decl), vis, span)
    }
    case IExternType(decl) -> {
      // Deduplicate extern types by their CLR target so the *same* extern type
      // (e.g. `extern type List[T] = "System.Collections.Generic.List`1"`,
      // threaded into many packages) always resolves to one canonical `TypeId`.
      // Without this, each registration gets a fresh id, and type identity breaks
      // when two references resolve to different registrations — e.g. `List[String]`
      // resolving to `List#127` while `newList()`'s `List[T]` resolves to `List#4`
      // produced a spurious `T0060` whose appearance depended on registration
      // order (#2394).
      val tid = if decl.clrName.length > 0 {
        match findExternTypeIdByClr(tbl, decl.clrName) {
          case Some(existing) -> existing
          case None -> freshTypeId(ctr)
        }
      } else {
        freshTypeId(ctr)
      }
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKExternType(id = tid, decl = decl), vis, span)
    }
    case IFunc(decl) -> {
      checkReservedBuiltinFuncDecl(diag, isImported, originPkg, decl.name, span)
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKFunc(decl = decl), vis, span)
    }
    case IExternFunc(decl) -> {
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
    case IFixture(decl) -> {
      val _ = addSym(tbl, diag, isImported, originPkg, decl.name, DKFixture(decl = decl), vis, span)
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
    }
    case IImpl(_) -> {
    }
    // conformance registered post-resolution; see registerImplsFromItems
    case IError -> {
    }
  }
}

// Record each `impl Iface for Target` conformance keyed by resolved `TypeId`,
// so the argument-position interface-subtyping check (#1488) can accept a
// `Target` value where an `Iface` parameter is expected.  Keying on `TypeId`
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
}

// Wrap a `ModulePath` as a `TypeExpr` reference so `resolveType` can resolve an
// interface head (a `ConstraintRef`) the same way it resolves a type position.
func mkTypeRef(path: in ModulePath, span: in Span): TypeExpr {
  TypeExpr(kind = TRef(path = path), span = span)
}

// The `TypeId` of a resolved user type, or `None` for non-`TyUser` types.
func typeIdOfType(t: in Type): Option[TypeId] {
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

func spanWithin(inner: in Span, outer: in Span): Bool {
  inner.startPos.offset >= outer.startPos.offset and inner.endPos.offset <= outer.endPos.offset
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
          val known = if cr.head.segments.count == 1 { isKnownDeriveMarker(cname) } else { false }
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

// Return true if any expression in the block/statement/expr tree is EYield,
// without descending into nested ELambda bodies.
// Mirror of AsyncStateMachine.bodyContainsYield; kept here because
// Lyric.TypeChecker cannot depend on Lyric.Emitter.  Keep both in sync.
func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_) -> true
    case ELambda(_, _) -> false
    // yield inside a lambda is not a generator yield
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EResult -> false
    case EError -> false
    case EParen(inner) -> exprContainsYield(inner)
    case EAwait(inner) -> exprContainsYield(inner)
    case ESpawn(inner) -> exprContainsYield(inner)
    case EOld(inner) -> exprContainsYield(inner)
    case EPropagate(inner) -> exprContainsYield(inner)
    case ETry(inner) -> exprContainsYield(inner)
    case EPrefix(_, inner) -> exprContainsYield(inner)
    case ETuple(elems) -> listAnyExprContainsYield(elems)
    case EList(elems) -> listAnyExprContainsYield(elems)
    case EInterpolated(segs) -> {
      var found = false
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> {
            if exprContainsYield(se) {
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
    case EBinop(_, l, r) -> exprContainsYield(l) or exprContainsYield(r)
    case EAssign(t, _, v) -> exprContainsYield(t) or exprContainsYield(v)
    case EMember(recv, _) -> exprContainsYield(recv)
    case ETypeApp(f, _) -> exprContainsYield(f)
    case EIndex(recv, idxs) -> exprContainsYield(recv) or listAnyExprContainsYield(idxs)
    case ECall(f, args) -> {
      if exprContainsYield(f) {
        return true
      }
      var i = 0
      while i < args.count {
        val found = match args[i] {
          case CAPositional(v) -> exprContainsYield(v)
          case CANamed(_, v, _) -> exprContainsYield(v)
        }
        if found {
          return true
        }
        i = i + 1
      }
      false
    }
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> exprContainsYield(a) or exprContainsYield(b)
      case RBHalfOpen(a, b, _) -> exprContainsYield(a) or exprContainsYield(b)
      case RBLowerOpen(a) -> exprContainsYield(a)
      case RBUpperOpen(a) -> exprContainsYield(a)
    }
    case EIf(c, t, eOpt, _) -> {
      if exprContainsYield(c) {
        return true
      }
      val inT = match t { case EOBExpr(te) -> exprContainsYield(te); case EOBBlock(tb) -> blockContainsYield(tb) }
      if inT {
        return true
      }
      match eOpt {
        case None -> false
        case Some(b) -> match b { case EOBExpr(ee) -> exprContainsYield(ee); case EOBBlock(eb) -> blockContainsYield(eb) }
      }
    }
    case EMatch(subj, arms) -> {
      if exprContainsYield(subj) {
        return true
      }
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val inGuard = match arm.guard { case None -> false; case Some(g) -> exprContainsYield(g) }
        if inGuard {
          return true
        }
        val inBody = match arm.body { case EOBExpr(ae) -> exprContainsYield(ae); case EOBBlock(ab) -> blockContainsYield(ab) }
        if inBody {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> blockContainsYield(blk)
    case EUnsafe(blk) -> blockContainsYield(blk)
    case EForall(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYield(we) }
      inW or exprContainsYield(body)
    }
    case EExists(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYield(we) }
      inW or exprContainsYield(body)
    }
  }
}

func listAnyExprContainsYield(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if exprContainsYield(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContainsYield(stmt: in Statement): Bool {
  match stmt.kind {
    case SExpr(e) -> exprContainsYield(e)
    case SThrow(e) -> exprContainsYield(e)
    case SReturn(Some(e)) -> exprContainsYield(e)
    case SReturn(None) -> false
    case SBreak(_) -> false
    case SContinue(_) -> false
    case SInvariant(_) -> false
    case SItem(_) -> false
    case SAssign(t, _, v) -> exprContainsYield(t) or exprContainsYield(v)
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> exprContainsYield(e)
      case LBLet(_, _, e) -> exprContainsYield(e)
      case LBVar(_, _, Some(e)) -> exprContainsYield(e)
      case LBVar(_, _, None) -> false
    }
    case STry(body, catches, finally_) -> {
      if blockContainsYield(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockContainsYield(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContainsYield(fb)
      }
    }
    case SDefer(b) -> blockContainsYield(b)
    case SScope(_, b) -> blockContainsYield(b)
    case SLoop(_, b) -> blockContainsYield(b)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SWhile(_, cond, body) -> exprContainsYield(cond) or blockContainsYield(body)
    case SRule(l, r) -> exprContainsYield(l) or exprContainsYield(r)
  }
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
        hasDefault = match p.dflt { case None -> false; case Some(_) -> true },
        span = p.span,
        tyExpr = Some(value = p.ty)
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
    match items[i].kind {
      case IFunc(decl) -> addFuncSig(tbl, diag, sigs, decl, false, isImported, pkgName)
      case IExternFunc(decl) -> addFuncSig(tbl, diag, sigs, externFuncAsFunctionDecl(decl), true, isImported, pkgName)
      case _ -> {
      }
    }
    i = i + 1
  }
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
  // Imported stdlib functions don't get to shadow the codegen builtins.
  // `println`, `toString`, `panic`, `assert`, `expect`, `default`,
  // `format1`, `format2` are wired in `codegenBuiltinType` with
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
  val sg0 = resolveFunctionSig(tbl, diag, pkgName, decl)
  val sg = if isExternFunc { asExternFuncSig(sg0) } else { sg0 }
  val arityKey = decl.name + "/" + toString(decl.params.count)
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
    if not sigs.containsKey(decl.name) {
      sigs.add(decl.name, sg)
    }
    if not sigs.containsKey(arityKey) {
      sigs.add(arityKey, sg)
    }
  } else {
    if sigs.containsKey(decl.name) {
      sigs.remove(decl.name)
    }
    sigs.add(decl.name, sg)
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
  registerOverloadCandidate(sigs, byNameSigKey(decl.name), sg)
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
  name == "println" or name == "toString" or name == "panic" or name == "default" or name == "expect" or
    name == "assert" or
    name == "format1" or
    name == "format2"
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
  name == "println" or name == "print" or name == "panic" or name == "assert" or name == "toString" or name == "default" or
    name == "expect" or
    name == "format1" or
    name == "format2" or
    name == "format3" or
    name == "format4" or
    name == "hashCode" or
    name == "__lyric_protected_wait" or
    name == "__lyric_protected_notify"
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
          hasDefault = match p.dflt { case None -> false; case Some(_) -> true },
          span = p.span,
          tyExpr = Some(value = p.ty)
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
                        false,
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
        tyExpr = rp.tyExpr
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
    case TyArray(sz, elem) -> TyArray(size = sz, element = substitutesSelf(elem, selfTy))
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
                  val ictx = newGenericContext()
                  var pi = 0
                  while pi < sig.params.count {
                    val ifacePTy = substitutesSelf(resolveIfaceType(tbl, ifaceSym, ictx, diag, sig.params[pi].ty), selfTy)
                    val implPTy = substitutesSelf(resolveType(tbl, ctx, diag, fn.params[pi].ty), selfTy)
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
                    match sig.ret {
                      case None -> TyPrim(pt = PtUnit)
                      case Some(te) -> resolveIfaceType(tbl, ifaceSym, ictx, diag, te)
                    },
                    selfTy
                  )
                  val implRetTy = substitutesSelf(
                    match fn.ret { case None -> TyPrim(pt = PtUnit); case Some(te) -> resolveType(tbl, ctx, diag, te) },
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
                }
              }
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
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
      case RMFunc(fn) -> checkMemberSigTypes(tbl, diag, decl.generics, fn.generics, fn.params, fn.ret)
      case RMInvariant(_) -> {
      }
    }
    i = i + 1
  }
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
    case EForall(_, w, body) -> {
      match w {
        case None -> {
        }
        case Some(we) -> checkExprSelfMembers(diag, ctx, we)
      }
      checkExprSelfMembers(diag, ctx, body)
    }
    case EExists(_, w, body) -> {
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
        val syntheticBody: Option[FunctionBody] = Some(value = entryDecl.body)
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
        checkFunctionBody(tbl, sigs, diag, fn, sig, fieldLocals, fieldLocals, true, selfTy)
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
        checkFunctionBody(tbl, sigs, diag, fn, sig, fieldLocals, fieldLocals, true, selfTy)
      }
      case _ -> {
      }
    }
    i = i + 1
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
        checkFunctionBody(tbl, sigs, diag, fn, sig, fieldLocals, fieldLocals, true, selfTy)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// #6487: find the `RecordDecl` backing a resolved record/exposed-record
// `TypeId`, reusing the same symbol-table walk `fieldsOfRecord` (exprs.l)
// does — needed here (rather than `fieldsOfRecord`'s already-`Type`-resolved
// output) because `implTargetFieldLocals` must re-resolve each field through
// `recordFieldLocals` to get `LocalBinding.isMutable`, which `FieldEntry`
// does not carry.
func findRecordDeclByTypeId(tbl: in SymbolTable, tid: in TypeId): Option[RecordDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, rd) -> {
        if typeIdEq(did, tid) {
          return Some(value = rd)
        }
      }
      case DKExposedRec(did, rd) -> {
        if typeIdEq(did, tid) {
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

func findProtectedDeclByTypeId(tbl: in SymbolTable, tid: in TypeId): Option[ProtectedTypeDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKProtected(did, pd) -> {
        if typeIdEq(did, tid) {
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
        if other.span.startPos.offset == decl.span.startPos.offset and other.span.endPos.offset == decl.span.endPos.offset {
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
        if other.span.startPos.offset == decl.span.startPos.offset and other.span.endPos.offset == decl.span.endPos.offset {
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
        checkFunctionBody(tbl, sigs, diag, fn, sig, fieldLocals, fieldLocals, true, selfTy)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func checkDeclTypeRefs(tbl: in SymbolTable, diag: in List[Diagnostic], items: in List[Item]): Unit {
  val emptyCtx = newGenericContext()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IRecord(decl) -> checkRecordDeclTypes(tbl, diag, decl)
      case IExposedRec(decl) -> checkRecordDeclTypes(tbl, diag, decl)
      case IUnion(decl) -> checkUnionDeclTypes(tbl, diag, decl)
      case IInterface(decl) -> checkInterfaceDeclTypes(tbl, diag, decl)
      case IOpaque(decl) -> checkOpaqueDeclTypes(tbl, diag, decl)
      case IProtected(decl) -> checkProtectedDeclTypes(tbl, diag, decl)
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
  val ctx = newGenericContext()
  if genericNames.count > 0 {
    gctxPush(ctx, genericNames)
  }
  val scratch: List[Diagnostic] = newList()
  val declT = resolveType(tbl, ctx, scratch, te)
  val noRte: Option[TypeExpr] = None
  val noSelfFields: Map[String, Type] = newMap()
  val sc = newScopeForFunction(TyError, genericNames, noRte, noSelfFields, false, TyError)
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

// Every declared initialiser `item` carries, checked by `checkDeclaredInit`.
func checkItemDeclaredInits(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  item: in Item,
): Unit {
  val noGenerics: List[String] = newList()
  match item.kind {
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
    case IFunc(decl) -> checkParamDefaults(tbl, sigs, diag, extractGenericNames(decl.generics), decl.name, decl.params)
    case IExternFunc(decl) -> checkParamDefaults(tbl, sigs, diag, noGenerics, decl.name, decl.params)
    case IRecord(decl) -> checkRecordDeclaredInits(tbl, sigs, diag, decl)
    case IExposedRec(decl) -> checkRecordDeclaredInits(tbl, sigs, diag, decl)
    case IOpaque(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case OMField(fd) -> checkFieldDefault(tbl, sigs, diag, owner, decl.name, fd.name, fd.ty, fd.dflt)
          case OMInvariant(_) -> ()
        }
      }
    }
    case IProtected(decl) -> {
      val owner = extractGenericNames(decl.generics)
      for m in decl.members {
        match m {
          case PMField(pf) -> match pf {
            case PFVar(name, ty, init, _, _, _) -> checkFieldDefault(
              tbl,
              sigs,
              diag,
              owner,
              decl.name,
              name,
              ty,
              init
            )
            case PFLet(name, ty, init, _, _, _) -> checkFieldDefault(
              tbl,
              sigs,
              diag,
              owner,
              decl.name,
              name,
              ty,
              init
            )
            case PFImmutable(fd) -> checkFieldDefault(
              tbl,
              sigs,
              diag,
              owner,
              decl.name,
              fd.name,
              fd.ty,
              fd.dflt
            )
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

func checkRecordDeclaredInits(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  decl: in RecordDecl,
): Unit {
  val owner = recordDeclGenericNames(decl)
  for m in decl.members {
    match m {
      case RMField(fd) -> checkFieldDefault(tbl, sigs, diag, owner, decl.name, fd.name, fd.ty, fd.dflt)
      case RMFunc(fn) -> checkParamDefaults(tbl, sigs, diag, concatGenericNames(owner, fn.generics), fn.name, fn.params)
      case RMInvariant(_) -> ()
    }
  }
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
  /// selective or aliased).  A file that imports this package whole sees
  /// these packages' names bare too (docs/01 §9.2, D141); the others it
  /// does not.
  wholeImports: List[String]
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

// Install the docs/01 §9.2 import rule for the file being checked (#7463):
// a whole import (`import P`) makes every name of `P` visible bare, and so,
// transitively, do the packages `P` itself imports whole (the kernel/host
// re-export idiom); a selective import (`import P.{f, T}`) makes only the
// listed names visible; an aliased import (`import P as Q`) makes none
// visible bare, since they are reached as `Q.f`.
func installImportRule(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  userPkg: in String,
  imports: in List[ImportDecl],
  importedPackages: in List[ImportedPackage],
  fileItems: in List[Item],
): Unit {
  val whole: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  val names: List[String] = newList()
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
          val items = match sel {
            case ISGroup(group) -> group
            case ISSingle(one) -> {
              val single: List[ImportItem] = newList()
              single.add(one)
              single
            }
          }
          var k = 0
          while k < items.count {
            match items[k].asAlias {
              // A renamed item (`P.{f as g}`, #7564) makes `g`, not `f`,
              // visible bare; `Lyric.AliasRewriter` has already rewritten
              // each use of `g` to `P.f`.  `g` is checked for collisions
              // below.
              case Some(renamed) -> renames.add(
                RenamedImport(local = renamed, pkg = pkg, name = items[k].name, span = items[k].span)
              )
              case None -> names.add(pkg + "|" + items[k].name)
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
            }
          }
        }
      }
    }
    i = i + 1
  }
  var w = 0
  while w < whole.count {
    var p = 0
    while p < importedPackages.count {
      if importedPackages[p].name == whole[w] {
        val deps = importedPackages[p].wholeImports
        var d = 0
        while d < deps.count {
          if not seen.containsKey(deps[d]) {
            seen.add(deps[d], true)
            whole.add(deps[d])
          }
          d = d + 1
        }
      }
      p = p + 1
    }
    w = w + 1
  }
  checkRenamedImports(diag, renames, names, whole, aliasPkgs, aliasNames, importedPackages, fileItems)
  symTableSetImportRule(tbl, userPkg, whole, names, aliasPkgs, aliasNames)
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
        // Native lowers the full `extern func` surface (callbacks, `String`);
        // the managed targets marshal only the types every runtime passes
        // the same way.
        if libCount > 0 and libOk and not native {
          for p in decl.params {
            checkCBindingType(diag, decl.name, p.ty, false)
          }
          match decl.ret {
            case Some(te) -> checkCBindingType(diag, decl.name, te, true)
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
  }
}

// T0151 unless `te` is a type a C binding passes the same way on every
// target: `Int` (int32), `Long` (int64), `Byte` (uint8), `Double`
// (double), a `NativePtr[T]` (a pointer), or, as a result, `Unit` (void).
// `Float` is excluded: MSIL and native carry it as a 64-bit double, so a C
// `float` would receive the wrong bits (#7966).
func checkCBindingType(diag: in List[Diagnostic], fname: in String, te: in TypeExpr, isResult: in Bool): Unit {
  val ok = match te.kind {
    case TRef(path) -> {
      val n = path.segments[path.segments.count - 1]
      path.segments.count == 1 and (n == "Int" or n == "Long" or n == "Byte" or n == "Double" or (isResult and n == "Unit"))
    }
    case TGenericApp(head, _) -> head.segments.count == 1 and head.segments[0] == "NativePtr"
    case TUnit -> isResult
    case TParen(inner) -> {
      checkCBindingType(diag, fname, inner, isResult)
      return
    }
    case _ -> false
  }
  if not ok {
    diag.add(
      errorDiagnostic(
        "T0151",
        "extern func '" + fname + "': this type cannot cross a C binding; use Int, Long, Byte, Double or NativePtr[T]" +
          (if isResult { ", or Unit for no result" } else { "" }),
        te.span
      )
    )
  }
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
// Deduplicates by external FQN so repeated imports of the same external type
// share one canonical TypeId (matching the behavior of `extern type`).
// Public (`pub use extern`) and private (`import extern`) imports are both
// supported with correct visibility semantics.
pub func registerExternalImports(
  tbl: in SymbolTable,
  ctr: in TypeIdCounter,
  diag: in List[Diagnostic],
  imports: in List[ImportDecl],
): Unit {
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
            val tid = match findExternTypeIdByClr(tbl, externalFqn) {
              case Some(existing) -> existing
              case None -> freshTypeId(ctr)
            }
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
          val tid = match findExternTypeIdByClr(tbl, externalFqn) {
            case Some(existing) -> existing
            case None -> freshTypeId(ctr)
          }
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
          val tid = match findExternTypeIdByClr(tbl, externalFqn) {
            case Some(existing) -> existing
            case None -> freshTypeId(ctr)
          }
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
  checkWithImportedPackagesCore(file, importedPackages, true, false)
}

/// `checkWithImportedPackages` for a `--target native` build: the file may
/// also use the native-only FFI intrinsics (docs/01 §11.6) — the
/// `NativeWeak[T]` type and the `nativeAddrOf`, `NativeWeak` and `upgrade`
/// calls — which no other target can lower.  `NativePtr[T]` and
/// `nativeNullPtr()` exist on every target (D158).
pub func checkWithImportedPackagesForNative(
  file: in SourceFile, importedPackages: in List[ImportedPackage]
): CheckResult {
  checkWithImportedPackagesCore(file, importedPackages, true, true)
}

// The FFI intrinsic types.  Every backend lowers them by name, so they are
// declared here only to give their uses a type; the `clrName`s name no CLR
// or JVM class and are never resolved.  `NativePtr[T]` is the raw pointer of
// a C binding (`extern func`, D158) on every target; `NativeWeak[T]` exists
// only on the native target, which alone has ARC.
val ffiIntrinsicTypesSource: String = "package Lyric.NativeIntrinsics\n" + "extern type NativePtr[T] = \"lyric.native.NativePtr\"\n"

val nativeIntrinsicTypesSource: String = ffiIntrinsicTypesSource + "extern type NativeWeak[T] = \"lyric.native.NativeWeak\"\n"

// Register the FFI intrinsic types with no declaring package, so every file
// sees them bare with no import, as codegen does.  They are registered
// before any other package, so a type of the same name declared anywhere
// else shadows them.  `native` adds the native-only `NativeWeak[T]`.
func registerNativeIntrinsicTypes(tbl: in SymbolTable, ctr: in TypeIdCounter, native: in Bool): Unit {
  val pr = parse(if native then nativeIntrinsicTypesSource else ffiIntrinsicTypesSource)
  val scratch: List[Diagnostic] = newList()
  for it in pr.file.items {
    registerItem(tbl, ctr, scratch, true, "", it)
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
  checkWithImportedPackagesCore(file, empty, false, false)
}

func checkWithImportedPackagesCore(
  file0: in SourceFile,
  importedPackages: in List[ImportedPackage],
  validateDecls: in Bool,
  nativeIntrinsics: in Bool,
): CheckResult {
  val diag: List[Diagnostic] = newList()
  val tbl = newSymbolTable()
  val ctr = newTypeIdCounter()
  registerNativeIntrinsicTypes(tbl, ctr, nativeIntrinsics)

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
  val userImports = collectImportNames(file.imports)

  // T1: register imported items first (shadow without error), tagging each
  // symbol with its declaring package so scoped resolution can prefer it.
  var p = 0
  while p < importedPackages.count {
    val ip = importedPackages[p]
    // T0144 in another package is that package's own build error.
    val ipDiag: List[Diagnostic] = newList()
    val ipItems = desugarModuleValItems(ip.items, ipDiag)
    var ii = 0
    while ii < ipItems.count {
      registerItem(tbl, ctr, diag, true, ip.name, ipItems[ii])
      ii = ii + 1
    }
    p = p + 1
  }
  var j = 0
  while j < file.items.count {
    registerItem(tbl, ctr, diag, false, userPkg, file.items[j])
    j = j + 1
  }

  // T1.5: register external imports from `import extern` declarations (D105, Phase 2a).
  // This must happen after T1 so regular Lyric types are already in scope for
  // shadowing, and before symTableSetScope so the scope is computed afterward.
  registerExternalImports(tbl, ctr, diag, file.imports)

  // From here on, resolve under the user package's scope by default: the
  // user's own declarations win, then its imports, then last-registered.
  symTableSetScope(tbl, userPkg, userImports)

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
  // Imported-item signature resolution runs against a *scratch* diagnostic
  // list so that internal stdlib type references the bridge can't satisfy
  // (e.g. obscure kernel-internal types like `Scope`, or wire-shape gaps
  // the self-hosted typechecker hasn't grown coverage for yet) don't pollute
  // the user package's diagnostics and trip `reportAndAbort` on a build the
  // user authored cleanly.  The signatures are still recorded in `sigs`
  // (with `TyError` for any unresolved type refs); the user's typecheck
  // can still call any stdlib function whose signature *does* resolve, and
  // codegen tolerates residual `TyError` via the existing fallback paths.
  // Each package's sigs resolve under its own scope so a type ref binds to the
  // declaring package's type, not a same-named sibling's (the RegexError case).
  val sigs: Map[String, ResolvedSignature] = newMap()
  val importedDiag: List[Diagnostic] = newList()
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
    addSigsFromItems(tbl, importedDiag, sigs, ip2.items, true, ip2.name)
    registerImplsFromItems(tbl, newGenericContext(), implDiag, ip2.items)
    addMethodSigsFromItems(tbl, ip2.items, ip2.name)
    sp = sp + 1
  }

  // User signatures + bodies resolve under the user package's scope, and
  // its bare names under the file's import rule.
  symTableSetScope(tbl, userPkg, userImports)
  symTableRegisterPackageImports(tbl, userPkg, userImports)
  installImportRule(tbl, diag, userPkg, file.imports, importedPackages, file.items)
  checkExternFuncBindings(diag, file.items, nativeIntrinsics)
  addSigsFromItems(tbl, diag, sigs, file.items, false, userPkg)
  registerImplsFromItems(tbl, newGenericContext(), implDiag, file.items)
  addMethodSigsFromItems(tbl, file.items, userPkg)

  // T4: validate declaration-position type references (#1228) so an unknown
  // type in a record/union/interface/opaque/protected/alias/val declaration
  // errors at the declaration instead of silently degrading to Object.
  // Skipped for synthesised contract-surface checks (see checkContractSurface).
  if validateDecls {
    checkDeclTypeRefs(tbl, diag, file.items)
  }

  // T5: check user function bodies.
  var m = 0
  while m < file.items.count {
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
        checkImplMemberBodies(tbl, sigs, diag, decl)
      }
      case IProtected(decl) -> checkProtectedMemberBodies(tbl, sigs, diag, decl)
      case IRecord(decl) -> checkRecordMemberBodies(tbl, sigs, diag, decl)
      case IExposedRec(decl) -> checkRecordMemberBodies(tbl, sigs, diag, decl)
      case IConfig(decl) -> checkConfigBlock(diag, decl)
      case IAspect(decl) -> checkAspectConfigRanges(diag, decl)
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
