//! ifacebuild_walk.l - the interface producer (docs/70 §9.2, §9.3): builds a
//! package's `Lyric.Iface.Iface` from its checked source.
//!
//! The declarations come from the same walk over the items that the resolver
//! makes (`Lyric.Resolve`, `resolve_collect.l`), with the same DefPaths, so an
//! interface and the resolver's table agree on what a package declares.  Each
//! declaration's written types are resolved by the checker (`resolveType`
//! against the checked package's symbol table) and converted to `Ty`
//! (`Lyric.IfaceConv`).  Only what a consumer can name is recorded: `pub` and
//! `internal` declarations, and extern types.  Default values, contracts and
//! bodies are not recorded yet (D327).
package Lyric.IfaceBuild

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols
import Lyric.Tir.{Ty, TTypeParam, TLit, TExpr}
import Lyric.Tir.Build.{buildPackageDefaults, newTyConvCtx}
import Lyric.Iface
import Lyric.IfaceConv
import Lyric.ModeChecker
import Lyric.Resolve.{funcDefPath, methodDefPath, reexportsOf}
import Lyric.TypeChecker.{CheckResult, GenericContext, newGenericContext, gctxPushOwned, resolveType}

func visOf(v: in Option[Visibility]): IfVis {
  match v {
    case Some(vis) -> match vis { case VisPub(_) -> IfPublic; case VisInternal(_) -> IfInternal }
    case None -> IfPrivate
  }
}

func isVisible(v: in IfVis): Bool {
  match v {
    case IfPrivate -> false
    case _ -> true
  }
}

func genericNamesOf(gps: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gps {
    case None -> ()
    case Some(g) -> {
      for gp in g.params {
        match gp {
          case GPType(name, _) -> names.add(name)
          case GPValue(name, _, _) -> names.add(name)
        }
      }
    }
  }
  names
}

// A frame for a declaration at `path` with the generics `gps`.
func frameOf(bc: in BuildCtx, path: in DefPath, gps: in Option[GenericParams]): ConvFrame {
  ConvFrame(owner = internDefPath(bc.tbl.interner, path), names = genericNamesOf(gps))
}

func withFrame(frames: in List[ConvFrame], f: in ConvFrame): List[ConvFrame] {
  val res: List[ConvFrame] = newList()
  for x in frames {
    res.add(x)
  }
  res.add(f)
  res
}

// `te` as the checker resolves it, with the generics of `frames` in scope.
func resolveTy(bc: in BuildCtx, frames: in List[ConvFrame], selfTy: in Option[Ty], te: in TypeExpr, what: in String): Ty {
  val ctx = newGenericContext()
  for f in frames {
    gctxPushOwned(ctx, f.names, "#" + toString(f.owner.id))
  }
  val diag: List[Diagnostic] = newList()
  val t = resolveType(bc.tbl, ctx, diag, te)
  if diag.count > 0 {
    buildFail(bc, what + ": " + diag[0].message)
  }
  tyOf(bc, frames, selfTy, t, what)
}

func constraintTypeArgs(bc: in BuildCtx, frames: in List[ConvFrame], cr: in ConstraintRef, what: in String): List[Ty] {
  val res: List[Ty] = newList()
  for a in cr.args {
    match a {
      case TAType(te) -> res.add(resolveTy(bc, frames, None, te, what))
      case TAValue(_) -> buildFail(bc, what + ": a value argument in a constraint is not recorded")
    }
  }
  res
}

func boundsFor(
  bc: in BuildCtx, frames: in List[ConvFrame], wc: in Option[WhereClause], name: in String, what: in String
): List[Ty] {
  val res: List[Ty] = newList()
  match wc {
    case None -> ()
    case Some(clause) -> {
      for b in clause.bounds {
        if b.name == name {
          for cr in b.constraints {
            res.add(boundTy(bc, modulePathJoin(cr.head.segments), constraintTypeArgs(bc, frames, cr, what)))
          }
        }
      }
    }
  }
  res
}

func typeParamsOf(
  bc: in BuildCtx,
  frames: in List[ConvFrame],
  gps: in Option[GenericParams],
  wc: in Option[WhereClause],
  what: in String,
): List[TTypeParam] {
  val res = mkTypeParams()
  match gps {
    case None -> ()
    case Some(g) -> {
      for gp in g.params {
        match gp {
          case GPType(name, _) -> res.add(mkTypeParam(name, boundsFor(bc, frames, wc, name, what), None))
          case GPValue(name, constraint, _) -> {
            val vt = resolveTy(bc, frames, None, constraint, what)
            res.add(mkTypeParam(name, boundsFor(bc, frames, wc, name, what), Some(value = vt)))
          }
        }
      }
    }
  }
  res
}

// ── Functions ────────────────────────────────────────────────────────────────
func annotationNamed(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if modulePathJoin(a.name.segments) == name {
      return true
    }
  }
  false
}

func ifVerifOf(v: in VerificationLevel): IfVerif {
  match v {
    case VLRuntimeChecked -> IfRuntimeChecked
    case VLProofRequired -> IfProofRequired
    case VLProofRequiredUnsafe -> IfProofRequiredUnsafe
    case VLProofRequiredChecked -> IfProofRequiredChecked
    case VLAxiom -> IfAxiom
  }
}

// The built default of parameter `name` of the function keyed `fnKey`, when the interface can record it.
func builtDefault(bc: in BuildCtx, fnKey: in String, name: in String): Option[TExpr] {
  match mapGet(bc.defaults, fnKey) {
    case Some(byName) -> match mapGet(byName, name) {
      case Some(d) -> if defaultCarriable(d) { Some(value = d) } else { None }
      case None -> None
    }
    case None -> None
  }
}

func paramsOf(
  bc: in BuildCtx, frames: in List[ConvFrame], selfTy: in Option[Ty], ps: in List[Param], what: in String
): List[IfParam] {
  val res: List[IfParam] = newList()
  for p in ps {
    val mode = match p.mode { case PMIn -> 0; case PMOut -> 1; case PMInout -> 2 }
    val hasDefault = match p.dflt { case Some(_) -> true; case None -> false }
    val param = mkParam(p.name, mode, resolveTy(bc, frames, selfTy, p.ty, what), hasDefault)
    res.add(param.copy(dflt = builtDefault(bc, what, p.name)))
  }
  res
}

// A callable's detail.  `outer` are the frames of the owner (a type's generics
// for a method); `path` the callable's own DefPath, whose generics make the
// innermost frame.
func callableDetail(
  bc: in BuildCtx,
  outer: in List[ConvFrame],
  selfTy: in Option[Ty],
  path: in DefPath,
  gps: in Option[GenericParams],
  wc: in Option[WhereClause],
  ps: in List[Param],
  ret: in Option[TypeExpr],
  isAsync: in Bool,
  isAxiom: in Bool,
  isPure: in Bool,
): IfDetail {
  val what = defPathKey(path)
  val frames = withFrame(outer, frameOf(bc, path, gps))
  val result = match ret { case Some(te) -> resolveTy(bc, frames, selfTy, te, what); case None -> tyUnitValue() }
  IfDFunc(
    typeParams = typeParamsOf(bc, frames, gps, wc, what),
    params = paramsOf(bc, frames, selfTy, ps, what),
    ret = result,
    isAsync = isAsync,
    isAxiom = isAxiom,
    isPure = isPure
  )
}

func funcDetail(
  bc: in BuildCtx,
  outer: in List[ConvFrame],
  selfTy: in Option[Ty],
  path: in DefPath,
  fn: in FunctionDecl,
  fileLevel: in VerificationLevel,
): IfDetail {
  val level = levelOfFunction(fileLevel, fn)
  callableDetail(
    bc,
    outer,
    selfTy,
    path,
    fn.generics,
    fn.whereClause,
    fn.params,
    fn.ret,
    fn.isAsync,
    vlIsAxiom(level),
    isFuncPure(fn)
  )
}

func sigDetail(
  bc: in BuildCtx, outer: in List[ConvFrame], selfTy: in Option[Ty], path: in DefPath, sig: in FunctionSig
): IfDetail {
  callableDetail(
    bc,
    outer,
    selfTy,
    path,
    sig.generics,
    sig.whereClause,
    sig.params,
    sig.ret,
    sig.isAsync,
    false,
    annotationNamed(sig.annotations, "pure")
  )
}

func emit(acc: in List[IfDecl], path: in DefPath, kind: in IfKind, vis: in IfVis, detail: in IfDetail) {
  acc.add(IfDecl(path = path, kind = kind, vis = vis, detail = detail))
}

func addMethod(
  bc: in BuildCtx,
  acc: in List[IfDecl],
  outer: in List[ConvFrame],
  selfTy: in Option[Ty],
  owner: in DefPath,
  fn: in FunctionDecl,
  vis: in IfVis,
  fileLevel: in VerificationLevel,
) {
  val path = methodDefPath(owner, fn.name, fn.params)
  emit(acc, path, IfKMethod, vis, funcDetail(bc, outer, selfTy, path, fn, fileLevel))
}

// ── Fields and cases ─────────────────────────────────────────────────────────
func fieldsOfRecord(
  bc: in BuildCtx, frames: in List[ConvFrame], members: in List[RecordMember], what: in String
): List[IfField] {
  val res: List[IfField] = newList()
  for m in members {
    match m {
      case RMField(f) -> {
        val hasDefault = match f.dflt { case Some(_) -> true; case None -> false }
        res.add(mkField(f.name, resolveTy(bc, frames, None, f.ty, what + "." + f.name), f.isMutable, hasDefault))
      }
      case _ -> ()
    }
  }
  res
}

func fieldsOfCase(
  bc: in BuildCtx, frames: in List[ConvFrame], fields: in List[UnionField], what: in String
): List[IfField] {
  val res: List[IfField] = newList()
  var i = 0
  for f in fields {
    match f {
      case UFNamed(name, ty, _) -> res.add(mkField(name, resolveTy(bc, frames, None, ty, what), false, false))
      case UFPos(ty, _) -> res.add(mkField("_" + toString(i), resolveTy(bc, frames, None, ty, what), false, false))
    }
    i = i + 1
  }
  res
}

// ── Constants ────────────────────────────────────────────────────────────────
// The literal an initialiser is, or `None`: only a plain literal is recorded as
// a constant's value.
func literalOf(e: in Expr): Option[TLit] {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, _, _) -> Some(value = mkLitInt(v))
      case LFloat(v, _, _) -> Some(value = mkLitFloat(v))
      case LChar(cp) -> Some(value = mkLitChar(cp))
      case LString(t) -> Some(value = mkLitString(t))
      case LTripleString(t) -> Some(value = mkLitString(t))
      case LRawString(t) -> Some(value = mkLitString(t))
      case LBool(b) -> Some(value = mkLitBool(b))
      case LUnit -> None
    }
    case EPrefix(op, inner) -> match op {
      case PreNeg -> match inner.kind {
        case ELiteral(lit) -> match lit {
          case LInt(v, _, _) -> Some(
            value = mkLitInt(
              0i64 - v
            )
          )
          case LFloat(v, _, _) -> Some(
            value = mkLitFloat(
              0.0 - v
            )
          )
          case _ -> None
        }
        case _ -> None
      }
      case _ -> None
    }
    case EParen(inner) -> literalOf(inner)
    case _ -> None
  }
}

// ── Range bounds ─────────────────────────────────────────────────────────────
func boundLong(bc: in BuildCtx, e: in Expr, what: in String): Option[Long] {
  val b = foldLiteralBound(e)
  if b.ok and not b.isFloat {
    Some(value = b.l)
  } else {
    buildFail(bc, what + ": a range bound that is not an integer literal cannot be recorded")
    None
  }
}

func refinedOf(bc: in BuildCtx, base: in Ty, rb: in RangeBound, what: in String): Ty {
  match rb {
    case RBClosed(lo, hi) -> mkRefined(base, boundLong(bc, lo, what), boundLong(bc, hi, what), true)
    case RBHalfOpen(lo, hi, _) -> mkRefined(base, boundLong(bc, lo, what), boundLong(bc, hi, what), false)
    case RBLowerOpen(hi) -> mkRefined(base, None, boundLong(bc, hi, what), true)
    case RBUpperOpen(lo) -> mkRefined(base, boundLong(bc, lo, what), None, false)
  }
}

// ── Items ────────────────────────────────────────────────────────────────────
func addRecordLike(
  bc: in BuildCtx,
  acc: in List[IfDecl],
  decl: in RecordDecl,
  kind: in IfKind,
  vis: in IfVis,
  fileLevel: in VerificationLevel,
) {
  val path = typeDefPath(bc.pkg, decl.name)
  val frame = frameOf(bc, path, decl.generics)
  val frames = withFrame(newList(), frame)
  val what = defPathKey(path)
  emit(
    acc,
    path,
    kind,
    vis,
    IfDRecord(
      typeParams = typeParamsOf(bc, frames, decl.generics, decl.whereClause, what),
      fields = fieldsOfRecord(bc, frames, decl.members, what)
    )
  )
  for m in decl.members {
    match m {
      case RMFunc(fn) -> addMethod(
        bc,
        acc,
        frames,
        Some(value = selfOfType(frame.owner, frame.names.count)),
        path,
        fn,
        vis,
        fileLevel
      )
      case _ -> ()
    }
  }
}

func addItem(bc: in BuildCtx, acc: in List[IfDecl], it: in Item, fileLevel: in VerificationLevel) {
  val vis = visOf(it.visibility)
  val pkg = bc.pkg
  match it.kind {
    case IExternType(decl) -> {
      val path = if decl.clrName.length > 0 { externTypeDefPath(decl.clrName) } else { typeDefPath(pkg, decl.name) }
      val frames = withFrame(newList(), frameOf(bc, path, decl.generics))
      emit(
        acc,
        path,
        IfKExternType,
        IfPublic,
        IfDExtern(typeParams = typeParamsOf(bc, frames, decl.generics, None, defPathKey(path)), host = decl.clrName)
      )
    }
    case _ -> if isVisible(vis) { addVisibleItem(bc, acc, it, vis, fileLevel) }
  }
}

func addVisibleItem(bc: in BuildCtx, acc: in List[IfDecl], it: in Item, vis: in IfVis, fileLevel: in VerificationLevel) {
  val pkg = bc.pkg
  match it.kind {
    case IRecord(decl) -> addRecordLike(bc, acc, decl, IfKRecord, vis, fileLevel)
    case IExposedRec(decl) -> addRecordLike(bc, acc, decl, IfKExposedRecord, vis, fileLevel)
    case IUnion(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val frames = withFrame(newList(), frameOf(bc, path, decl.generics))
      val what = defPathKey(path)
      emit(acc, path, IfKUnion, vis, IfDType(typeParams = typeParamsOf(bc, frames, decl.generics, decl.whereClause, what)))
      for c in decl.cases {
        val cpath = memberDefPath(path, c.name)
        emit(acc, cpath, IfKUnionCase, vis, IfDCase(fields = fieldsOfCase(bc, frames, c.fields, defPathKey(cpath))))
      }
    }
    case IEnum(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      emit(acc, path, IfKEnum, vis, IfDType(typeParams = mkTypeParams()))
      for c in decl.cases {
        emit(acc, memberDefPath(path, c.name), IfKEnumCase, vis, IfDCase(fields = newList()))
      }
    }
    case IOpaque(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val frames = withFrame(newList(), frameOf(bc, path, decl.generics))
      emit(
        acc,
        path,
        IfKOpaque,
        vis,
        IfDType(typeParams = typeParamsOf(bc, frames, decl.generics, decl.whereClause, defPathKey(path)))
      )
    }
    case IProtected(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val pframe = frameOf(bc, path, decl.generics)
      val frames = withFrame(newList(), pframe)
      emit(
        acc,
        path,
        IfKProtected,
        vis,
        IfDType(typeParams = typeParamsOf(bc, frames, decl.generics, decl.whereClause, defPathKey(path)))
      )
      for m in decl.members {
        match m {
          case PMFunc(fn) -> addMethod(
            bc,
            acc,
            frames,
            Some(value = selfOfType(pframe.owner, pframe.names.count)),
            path,
            fn,
            vis,
            fileLevel
          )
          case PMEntry(e) -> {
            val epath = methodDefPath(path, e.name, e.params)
            emit(
              acc,
              epath,
              IfKMethod,
              vis,
              callableDetail(bc, frames, None, epath, None, None, e.params, e.ret, false, false, false)
            )
          }
          case _ -> ()
        }
      }
    }
    case IDistinctType(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val frames = withFrame(newList(), frameOf(bc, path, decl.generics))
      val what = defPathKey(path)
      val base = resolveTy(bc, frames, None, decl.underlying, what)
      val underlying = match decl.rangeClause { case Some(rb) -> refinedOf(bc, base, rb, what); case None -> base }
      emit(
        acc,
        path,
        IfKDistinct,
        vis,
        IfDAlias(typeParams = typeParamsOf(bc, frames, decl.generics, None, what), underlying = underlying)
      )
    }
    case ITypeAlias(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val frames = withFrame(newList(), frameOf(bc, path, decl.generics))
      val what = defPathKey(path)
      emit(
        acc,
        path,
        IfKAlias,
        vis,
        IfDAlias(
          typeParams = typeParamsOf(bc, frames, decl.generics, None, what),
          underlying = resolveTy(bc, frames, None, decl.rhs, what)
        )
      )
    }
    case IInterface(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val frame = frameOf(bc, path, decl.generics)
      val frames = withFrame(newList(), frame)
      emit(
        acc,
        path,
        IfKInterface,
        vis,
        IfDType(typeParams = typeParamsOf(bc, frames, decl.generics, decl.whereClause, defPathKey(path)))
      )
      val selfSome = Some(value = selfOfInterface(frame.owner))
      for m in decl.members {
        match m {
          case IMSig(sig) -> {
            val mpath = methodDefPath(path, sig.name, sig.params)
            emit(acc, mpath, IfKMethod, vis, sigDetail(bc, frames, selfSome, mpath, sig))
          }
          case IMFunc(fn) -> addMethod(bc, acc, frames, selfSome, path, fn, vis, fileLevel)
          case IMAssoc(_) -> ()
        }
      }
    }
    case IFunc(decl) -> {
      val dot = indexOfDot(decl.name)
      if dot > 0 {
        val owner = typeDefPath(pkg, decl.name.substring(0, dot))
        val member = decl.name.substring(dot + 1)
        val path = methodDefPath(owner, member, decl.params)
        val ownerSelf = match mapGet(bc.owners, decl.name.substring(0, dot)) {
          case Some(n) -> Some(value = selfOfType(internDefPath(bc.tbl.interner, owner), n))
          case None -> None
        }
        emit(acc, path, IfKMethod, vis, funcDetail(bc, newList(), ownerSelf, path, decl, fileLevel))
      } else {
        val path = funcDefPath(pkg, decl.name, decl.params)
        emit(acc, path, IfKFunc, vis, funcDetail(bc, newList(), None, path, decl, fileLevel))
      }
    }
    case IExternFunc(decl) -> {
      val path = funcDefPath(pkg, decl.name, decl.params)
      emit(
        acc,
        path,
        IfKFunc,
        vis,
        callableDetail(bc, newList(), None, path, None, None, decl.params, decl.ret, false, false, false)
      )
    }
    case IConst(decl) -> {
      val what = pkg + "::" + decl.name
      emit(
        acc,
        topDefPath(pkg, decl.name),
        IfKConst,
        vis,
        IfDValue(ty = resolveTy(bc, newList(), None, decl.ty, what), mutable = false, value = literalOf(decl.init))
      )
    }
    case IVal(decl) -> {
      match decl.pattern.kind {
        case PBinding(name, None) -> {
          val what = pkg + "::" + name
          match decl.ty {
            case Some(te) -> emit(
              acc,
              topDefPath(pkg, name),
              IfKVal,
              vis,
              IfDValue(
                ty = resolveTy(bc, newList(), None, te, what),
                mutable = false,
                value = literalOf(decl.init)
              )
            )
            case None -> match mapGet(bc.tbl.moduleValTypes, name) {
              case Some(checked) -> emit(
                acc,
                topDefPath(pkg, name),
                IfKVal,
                vis,
                IfDValue(
                  ty = resolveTy(bc, newList(), None, checked, what),
                  mutable = false,
                  value = literalOf(decl.init)
                )
              )
              case None -> buildFail(bc, what + ": the checker recorded no type for this pub val")
            }
          }
        }
        case _ -> ()
      }
    }
    case IWire(decl) -> emit(acc, topDefPath(pkg, decl.name), IfKWire, vis, IfDNone)
    case IScopeKind(decl) -> emit(acc, topDefPath(pkg, decl.name), IfKScope, vis, IfDNone)
    case IConfig(decl) -> emit(acc, topDefPath(pkg, decl.name), IfKConfig, vis, IfDNone)
    case IAspect(decl) -> emit(acc, topDefPath(pkg, decl.name), IfKAspect, vis, IfDNone)
    case _ -> ()
  }
}

// The generic parameter count of a type the package declares.
func noteOwner(bc: in BuildCtx, it: in Item) {
  match it.kind {
    case IRecord(d) -> bc.owners.add(d.name, genericNamesOf(d.generics).count)
    case IExposedRec(d) -> bc.owners.add(d.name, genericNamesOf(d.generics).count)
    case IUnion(d) -> bc.owners.add(d.name, genericNamesOf(d.generics).count)
    case IOpaque(d) -> bc.owners.add(d.name, genericNamesOf(d.generics).count)
    case IProtected(d) -> bc.owners.add(d.name, genericNamesOf(d.generics).count)
    case IEnum(d) -> bc.owners.add(d.name, 0)
    case _ -> ()
  }
}

func indexOfDot(s: in String): Int {
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == "." {
      return i
    }
    i = i + 1
  }
  -1
}

// ── Entry point ──────────────────────────────────────────────────────────────
/// The interface of the checked package `res`: its declarations, re-exports
/// and header.  `builtAgainst` and `targets` are what the build knows (the
/// interfaces of its dependencies, the backends it produces).  Errors name each
/// declaration whose types could not be recorded.
pub func buildIface(
  res: in CheckResult, builtAgainst: in List[IfBuiltAgainst], targets: in List[String]
): Result[Iface, List[String]] {
  val file = res.file
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  val bc = newBuildCtx(res.symbols, pkg)
  val levelDiags: List[Diagnostic] = newList()
  val fileLevel = levelOfFile(file, levelDiags)
  val decls: List[IfDecl] = newList()
  for it in file.items {
    noteOwner(bc, it)
  }
  bc.defaults = buildPackageDefaults(newTyConvCtx(res.symbols), res.symbols, file)
  for it in file.items {
    addItem(bc, decls, it, fileLevel)
  }
  if bc.errs.count > 0 {
    return Err(error = bc.errs)
  }
  val anns: List[String] = newList()
  if annotationNamed(file.fileAnnotations, "pure") {
    anns.add("pure")
  }
  if annotationNamed(file.fileAnnotations, "io") {
    anns.add("io")
  }
  Ok(
    value = Iface(
      header = IfHeader(
        formatVersion = ifaceFormatVersion,
        pkg = pkg,
        builtAgainst = builtAgainst,
        verification = ifVerifOf(fileLevel),
        consumerAnnotations = anns,
        targets = targets
      ),
      decls = decls,
      reexports = reexportsOf(file.imports)
    )
  )
}

// ── Outcome, validation and diagnostics ──────────────────────────────────────
/// A built interface: its canonical bytes and their hash.
pub record BuiltIface {
  bytes: slice[Byte]
  hash: String
}

/// What building a package's interface came to.  `IOUnrecordable` is a
/// declaration the interface cannot record (T0223); `IORoundTrip` is a producer
/// bug, the written interface not reading back as the one built (I0005,
/// docs/70 §9.3).
pub union IfaceOutcome {
  case IOBuilt(built: BuiltIface)
  case IOUnrecordable(reasons: List[String])
  case IORoundTrip(message: String)
}

/// Builds the interface of `res`, writes it, reads it back with a fresh
/// interner and compares: the "consumer sees exactly what the library's checker
/// saw" property of docs/70 §9.3.
pub func buildIfaceOutcome(
  res: in CheckResult, builtAgainst: in List[IfBuiltAgainst], targets: in List[String]
): IfaceOutcome {
  match buildIface(res, builtAgainst, targets) {
    case Err(reasons) -> IOUnrecordable(reasons = reasons)
    case Ok(iface) -> {
      val it = res.symbols.interner
      match encodeIface(iface, it) {
        case Err(msg) -> {
          val reasons: List[String] = newList()
          reasons.add(msg)
          IOUnrecordable(reasons = reasons)
        }
        case Ok(bytes) -> {
          val other = newDefPathInterner()
          match decodeIface(bytes, other) {
            case Err(msg) -> IORoundTrip(message = "the interface does not read back: " + msg)
            case Ok(back) -> if dumpIface(back, other) != dumpIface(iface, it) {
              IORoundTrip(message = "the interface read back differs from the one built")
            } else {
              IOBuilt(built = BuiltIface(bytes = bytes, hash = ifaceHash(bytes)))
            }
          }
        }
      }
    }
  }
}

/// Whether the file declares `main`: the package is an executable, which no
/// other package depends on, so it embeds no interface.
pub func isExecutable(file: in SourceFile): Bool {
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if decl.name == "main" { return true }
      case _ -> ()
    }
  }
  false
}

/// The diagnostics of an outcome: T0223 for each declaration a library's
/// interface cannot record, I0005 for a round trip that fails.
pub func outcomeDiagnostics(o: in IfaceOutcome, file: in SourceFile): List[Diagnostic] {
  val res: List[Diagnostic] = newList()
  match o {
    case IOBuilt(_) -> ()
    case IOUnrecordable(reasons) -> {
      for r in reasons {
        res.add(errorDiagnostic("T0223", "the package interface cannot record " + r, file.span))
      }
    }
    case IORoundTrip(msg) -> res.add(errorDiagnostic("I0005", "internal: " + msg, file.span))
  }
  res
}

/// The canonical bytes of the interface the outcomes built, if one was.  A
/// pipeline call checks one package, so there is at most one built outcome and
/// the first is the only one.
pub func builtBytesOf(outcomes: in List[IfaceOutcome]): Option[slice[Byte]] {
  for o in outcomes {
    match o {
      case IOBuilt(b) -> return Some(value = b.bytes)
      case _ -> ()
    }
  }
  None
}
