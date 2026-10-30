//! Parameter defaults of a package's public callables, compiled into the
//! package as thunks (#7827, docs/45 §"Parameter defaults").
//!
//! A call that leaves out a defaulted argument splices the default at the
//! call.  A package restored from its compiled form is known to its
//! consumers only through its contract metadata, and a default expression is
//! written in the declaring package's scope (it may read the package's
//! private values), so it cannot be carried to the consumer as source.
//! Instead, once the type checker's results are desugared into the package
//! (`Lyric.Pipeline.pipeCheckAndMono`, before mono drops its public generic
//! functions), `synthesizeDefaultThunks` appends to it one public function
//! per defaulted parameter of each public callable (a free or dot-named
//! function, a record or exposed-record method, an interface member, an
//! `impl` method of a public type):
//!
//!     @no_aspect pub func __lyric_default__<kind><owner><name><param types><param>(): <ParamType> { <default> }
//!
//! (`Lyric.Parser.defaultThunkName`, an injective encoding of the callable's
//! kind, owner, name, parameter types and the parameter, #8085, #8097).  Its body is the parameter's default as the
//! type checker checked and desugared it, so a widening default already
//! carries its conversion, and no checker pass sees the expression twice.  The contract records the parameter's default as a call
//! to the thunk (`Lyric.ContractMeta`), and a consumer that leaves the
//! argument out calls the compiled thunk.  `@no_aspect` keeps an aspect that
//! matches public functions from wrapping it.
//!
//! A parameter whose type names a type parameter of the callable or of its
//! owner, or `Self`, gets no thunk: a thunk takes no arguments, so nothing
//! would bind the type parameter.  Its default is not exported.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

pub func synthesizeDefaultThunks(file: in SourceFile): SourceFile {
  // Functions already in the file: a thunk an earlier pass synthesised is
  // not added again.
  val existing: Map[String, Bool] = newMap()
  for it in file.items {
    match it.kind {
      case IFunc(fn) -> if not existing.containsKey(fn.name) { existing.add(fn.name, true) }
      case _ -> ()
    }
  }
  // Thunks added by this pass: one name reached twice is a collision.
  val addedNames: Map[String, Bool] = newMap()
  val pubTypes = publicTypeNames(file)
  val added: List[Item] = newList()
  for it in file.items {
    if isPublic(it.visibility) {
      match it.kind {
        case IFunc(fn) -> if not fn.name.startsWith(defaultThunkPrefix()) {
          addThunks(
            added,
            existing,
            addedNames,
            DTFunction,
            emptyNames(),
            fn.name,
            emptyNames(),
            fn.generics,
            fn.params,
            it.span
          )
        }
        case IRecord(decl) -> addRecordThunks(added, existing, addedNames, decl, it.span)
        case IExposedRec(decl) -> addRecordThunks(added, existing, addedNames, decl, it.span)
        case IInterface(decl) -> {
          val owner = genericNames(decl.generics)
          val ifaceOwner = singleName(decl.name)
          for m in decl.members {
            match m {
              case IMSig(sig) -> addThunks(
                added,
                existing,
                addedNames,
                DTInterfaceMember,
                ifaceOwner,
                sig.name,
                owner,
                sig.generics,
                sig.params,
                it.span
              )
              case IMFunc(fn) -> addThunks(
                added,
                existing,
                addedNames,
                DTInterfaceMember,
                ifaceOwner,
                fn.name,
                owner,
                fn.generics,
                fn.params,
                it.span
              )
              case IMAssoc(_) -> ()
            }
          }
        }
        case _ -> ()
      }
    }
    // An impl has no visibility of its own; it is exported with its target.
    match it.kind {
      case IImpl(decl) -> {
        val target = thunkImplTarget(decl)
        // A generic impl exports no defaults (D168 item 4): its methods'
        // heads would name type parameters the contract's `impl` head does
        // not declare (#8099).
        if target.length > 0 and pubTypes.containsKey(target) and not implIsGeneric(decl) {
          val owner: List[String] = newList()
          owner.add(target)
          owner.add(lastSegment(decl.iface.head.segments))
          val implGenerics = genericNames(decl.generics)
          for m in decl.members {
            match m {
              case IMplFunc(fn) -> addThunks(
                added,
                existing,
                addedNames,
                DTImplMethod,
                owner,
                fn.name,
                implGenerics,
                fn.generics,
                fn.params,
                it.span
              )
              case IMplAssoc(_) -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  if added.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    items.add(it)
  }
  for a in added {
    items.add(a)
  }
  SourceFile(
    moduleDoc = file.moduleDoc, files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

/// A default that holds a lambda literal, moved into a private function that
/// returns it: `f: () -> Int = { -> 1 }` becomes `f: () -> Int = __lyric_lamdef_0()`
/// beside `func __lyric_lamdef_0(): () -> Int { { -> 1 } }`.  A backend that
/// lifts lambda literals before lowering (`--target dotnet`) finds the lambda
/// once, in the thunk's body, instead of once per call that splices the
/// default, which it has no lifted body for (#8302).  A default whose type or
/// value names a type parameter of its callable or owner is left in place: a
/// nullary thunk has nothing to bind the parameter to.
pub func hoistLambdaDefaults(file: in SourceFile): SourceFile {
  val thunks: List[Item] = newList()
  val items: List[Item] = newList()
  for it in file.items {
    items.add(hoistItemLambdaDefaults(it, thunks))
  }
  if thunks.count == 0 {
    return file
  }
  for t in thunks {
    items.add(t)
  }
  file.copy(items = items)
}

func hoistItemLambdaDefaults(it: in Item, thunks: in List[Item]): Item {
  match it.kind {
    case IFunc(fn) -> it.copy(kind = IFunc(decl = hoistFuncLambdaDefaults(fn, emptyNames(), thunks)))
    case IRecord(decl) -> it.copy(kind = IRecord(decl = hoistRecordLambdaDefaults(decl, thunks)))
    case IExposedRec(decl) -> it.copy(kind = IExposedRec(decl = hoistRecordLambdaDefaults(decl, thunks)))
    case IImpl(decl) -> {
      val owner = genericNames(decl.generics)
      val members: List[ImplMember] = newList()
      for m in decl.members {
        members.add(
          match m {
            case IMplFunc(fn) -> IMplFunc(fn = hoistFuncLambdaDefaults(fn, owner, thunks))
            case IMplAssoc(a) -> IMplAssoc(assoc = a)
          }
        )
      }
      it.copy(kind = IImpl(decl = decl.copy(members = members)))
    }
    case IInterface(decl) -> {
      val owner = genericNames(decl.generics)
      val members: List[InterfaceMember] = newList()
      for m in decl.members {
        members.add(
          match m {
            case IMSig(sig) -> IMSig(
              sig = sig.copy(
                params = hoistParamLambdaDefaults(
                  sig.params,
                  owner,
                  genericNames(sig.generics),
                  thunks
                )
              )
            )
            case IMFunc(fn) -> IMFunc(fn = hoistFuncLambdaDefaults(fn, owner, thunks))
            case IMAssoc(a) -> IMAssoc(assoc = a)
          }
        )
      }
      it.copy(kind = IInterface(decl = decl.copy(members = members)))
    }
    case IProtected(decl) -> {
      val owner = genericNames(decl.generics)
      val members: List[ProtectedMember] = newList()
      for m in decl.members {
        members.add(
          match m {
            case PMFunc(fn) -> PMFunc(fn = hoistFuncLambdaDefaults(fn, owner, thunks))
            case PMEntry(en) -> PMEntry(
              entryDecl = en.copy(
                params = hoistParamLambdaDefaults(en.params, owner, emptyNames(), thunks)
              )
            )
            case other -> other
          }
        )
      }
      it.copy(kind = IProtected(decl = decl.copy(members = members)))
    }
    case _ -> it
  }
}

func hoistRecordLambdaDefaults(decl: in RecordDecl, thunks: in List[Item]): RecordDecl {
  val owner = genericNames(decl.generics)
  val members: List[RecordMember] = newList()
  for m in decl.members {
    members.add(
      match m {
        case RMField(f) -> match f.dflt {
          case Some(d) -> match hoistLambdaDefault(f.ty, d, owner, thunks) {
            case Some(call) -> RMField(field = f.copy(dflt = Some(value = call)))
            case None -> m
          }
          case None -> m
        }
        case RMFunc(fn) -> RMFunc(fn = hoistFuncLambdaDefaults(fn, owner, thunks))
        case other -> other
      }
    )
  }
  decl.copy(members = members)
}

func hoistFuncLambdaDefaults(fn: in FunctionDecl, owner: in List[String], thunks: in List[Item]): FunctionDecl {
  fn.copy(params = hoistParamLambdaDefaults(fn.params, owner, genericNames(fn.generics), thunks))
}

func hoistParamLambdaDefaults(
  params: in List[Param],
  owner: in List[String],
  own: in List[String],
  thunks: in List[Item],
): List[Param] {
  val inScope: List[String] = newList()
  for g in owner {
    inScope.add(g)
  }
  for g in own {
    inScope.add(g)
  }
  val res: List[Param] = newList()
  for p in params {
    match p.dflt {
      case Some(d) -> match hoistLambdaDefault(p.ty, d, inScope, thunks) {
        case Some(call) -> res.add(p.copy(dflt = Some(value = call)))
        case None -> res.add(p)
      }
      case None -> res.add(p)
    }
  }
  res
}

// A lambda literal default `{ n -> n + 1 }` of a function type
// `(Int) -> Int` with the parameter types the function type gives its
// unannotated parameters: moved out of the declaration it is no longer an
// argument of a call that would give them to a backend (#1939).
func annotateLambdaParams(d: in Expr, ty: in TypeExpr): Expr {
  match d.kind {
    case EParen(inner) -> d.copy(kind = EParen(inner = annotateLambdaParams(inner, ty)))
    case ELambda(ps, body) -> match ty.kind {
      case TFunction(pts, _) -> {
        if pts.count != ps.count {
          return d
        }
        val annotated: List[LambdaParam] = newList()
        var i = 0
        while i < ps.count {
          annotated.add(match ps[i].ty { case Some(_) -> ps[i]; case None -> ps[i].copy(ty = Some(value = pts[i])) })
          i = i + 1
        }
        d.copy(kind = ELambda(lambdaParams = annotated, body = body))
      }
      case TParen(inner) -> annotateLambdaParams(d, inner)
      case _ -> d
    }
    case _ -> d
  }
}

// The call that replaces the default `d` of type `ty`, with the thunk it
// calls added to `thunks`; None when `d` holds no lambda literal or names a
// type parameter in `inScope`.
func hoistLambdaDefault(ty: in TypeExpr, d: in Expr, inScope: in List[String], thunks: in List[Item]): Option[Expr] {
  val isLambda = { e: Expr -> match e.kind { case ELambda(_, _) -> true; case _ -> false } }
  if not anyInExpr(d, isLambda) or typeExprNamesAny(ty, inScope) or exprNamesAny(d, inScope) {
    return None
  }
  val name = "__lyric_lamdef_" + toString(thunks.count)
  thunks.add(thunkItem(name, ty, annotateLambdaParams(d, ty), d.span, false))
  val segs: List[String] = newList()
  segs.add(name)
  val noArgs: List[CallArg] = newList()
  Some(
    value = Expr(
      kind = ECall(
        fn = Expr(kind = EPath(path = ModulePath(segments = segs, span = d.span)), span = d.span),
        args = noArgs
      ),
      span = d.span
    )
  )
}

// The simple name of an `impl`'s target type, or "" for any other shape.
func thunkImplTarget(decl: in ImplDecl): String {
  match decl.target.kind {
    case TRef(path) -> lastSegment(path.segments)
    case TGenericApp(h, _) -> lastSegment(h.segments)
    case _ -> ""
  }
}

func addRecordThunks(
  added: in List[Item],
  existing: in Map[String, Bool],
  addedNames: in Map[String, Bool],
  decl: in RecordDecl,
  sp: in Span,
): Unit {
  val owner = genericNames(decl.generics)
  for m in decl.members {
    match m {
      case RMFunc(fn) -> addThunks(
        added,
        existing,
        addedNames,
        DTRecordMethod,
        singleName(decl.name),
        fn.name,
        owner,
        fn.generics,
        fn.params,
        sp
      )
      case _ -> ()
    }
  }
}

func addThunks(
  added: in List[Item],
  existing: in Map[String, Bool],
  addedNames: in Map[String, Bool],
  kind: in DefaultThunkKind,
  owner: in List[String],
  name: in String,
  ownerGenerics: in List[String],
  generics: in Option[GenericParams],
  params: in List[Param],
  sp: in Span,
): Unit {
  val inScope: List[String] = newList()
  for g in ownerGenerics {
    inScope.add(g)
  }
  for g in genericNames(generics) {
    inScope.add(g)
  }
  for p in params {
    match p.dflt {
      case Some(d) -> if not typeExprNamesAny(p.ty, inScope) and not exprNamesAny(d, inScope) {
        val thunk = defaultThunkName(kind, owner, name, params, p.name)
        if addedNames.containsKey(thunk) {
          panic(
            "internal compiler error: two parameter defaults map to the default thunk '" + thunk +
              "' (Lyric.Parser.defaultThunkName must be injective, #8097)"
          )
        }
        if not existing.containsKey(thunk) {
          addedNames.add(thunk, true)
          added.add(thunkItem(thunk, p.ty, d, sp, true))
        }
      }
      case None -> ()
    }
  }
}

func thunkItem(name: in String, ty: in TypeExpr, dflt: in Expr, sp: in Span, exported: in Bool): Item {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noAspect: List[Annotation] = newList()
  val noAspectSegs: List[String] = newList()
  noAspectSegs.add("no_aspect")
  val noArgs: List[AnnotationArg] = newList()
  noAspect.add(Annotation(name = ModulePath(segments = noAspectSegs, span = sp), args = noArgs, span = sp))
  val noParams: List[Param] = newList()
  val noContracts: List[ContractClause] = newList()
  val noGenerics: Option[GenericParams] = None
  val noWhere: Option[WhereClause] = None
  val vis: Option[Visibility] = if exported { Some(value = VisPub(span = sp)) } else { None }
  val fn = FunctionDecl(
    docComments = noDocs,
    annotations = noAspect,
    visibility = vis,
    isAsync = false,
    name = name,
    generics = noGenerics,
    params = noParams,
    ret = Some(value = ty),
    whereClause = noWhere,
    contracts = noContracts,
    body = Some(value = FBExpr(expr = dflt)),
    span = sp
  )
  Item(docComments = noDocs, annotations = noAnns, visibility = vis, kind = IFunc(decl = fn), span = sp)
}

func publicTypeNames(file: in SourceFile): Map[String, Bool] {
  val acc: Map[String, Bool] = newMap()
  for it in file.items {
    if isPublic(it.visibility) {
      val nm = match it.kind {
        case IRecord(r) -> r.name
        case IExposedRec(r) -> r.name
        case IUnion(u) -> u.name
        case IEnum(e) -> e.name
        case IOpaque(o) -> o.name
        case IProtected(p) -> p.name
        case IDistinctType(d) -> d.name
        case _ -> ""
      }
      if nm.length > 0 and not acc.containsKey(nm) {
        acc.add(nm, true)
      }
    }
  }
  acc
}

func isPublic(vis: in Option[Visibility]): Bool {
  match vis {
    case Some(v) -> match v { case VisPub(_) -> true; case VisInternal(_) -> false }
    case None -> false
  }
}

func singleName(name: in String): List[String] {
  val acc: List[String] = newList()
  acc.add(name)
  acc
}

func emptyNames(): List[String] {
  val acc: List[String] = newList()
  acc
}

func genericNames(generics: in Option[GenericParams]): List[String] {
  val acc: List[String] = newList()
  match generics {
    case Some(gps) -> {
      for gp in gps.params {
        match gp {
          case GPType(n, _) -> acc.add(n)
          case GPValue(n, _, _) -> acc.add(n)
        }
      }
    }
    case None -> ()
  }
  acc
}

func lastSegment(segs: in List[String]): String {
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

// True when `te` names `Self` or one of `names` anywhere in it: as a type
// (`T`, or the head of a path such as `T.Item`), or as a value an array
// length or value type argument uses (`array[N, Int]`, `Vec[N + 1]`).
func typeExprNamesAny(te: in TypeExpr, names: in List[String]): Bool {
  match te.kind {
    case TRef(path) -> pathNamesAny(path.segments, names)
    case TGenericApp(head, args) -> {
      if pathNamesAny(head.segments, names) {
        return true
      }
      for a in args {
        if typeArgNamesAny(a, names) {
          return true
        }
      }
      false
    }
    case TFunction(ps, r) -> {
      if typeExprNamesAny(r, names) {
        return true
      }
      for p in ps {
        if typeExprNamesAny(p, names) {
          return true
        }
      }
      false
    }
    case TTuple(ts) -> {
      for t in ts {
        if typeExprNamesAny(t, names) {
          return true
        }
      }
      false
    }
    case TSlice(elem) -> typeExprNamesAny(elem, names)
    case TArray(size, elem) -> typeArgNamesAny(size, names) or typeExprNamesAny(elem, names)
    case TNullable(inner) -> typeExprNamesAny(inner, names)
    case TParen(inner) -> typeExprNamesAny(inner, names)
    case TRefined(underlying, range) -> pathNamesAny(underlying.segments, names) or rangeNamesAny(range, names)
    case TSelf -> true
    case _ -> false
  }
}

func rangeNamesAny(r: in RangeBound, names: in List[String]): Bool {
  match r {
    case RBClosed(lo, hi) -> exprNamesAny(lo, names) or exprNamesAny(hi, names)
    case RBHalfOpen(lo, hi, _) -> exprNamesAny(lo, names) or exprNamesAny(hi, names)
    case RBLowerOpen(hi) -> exprNamesAny(hi, names)
    case RBUpperOpen(lo) -> exprNamesAny(lo, names)
  }
}

func pathNamesAny(segs: in List[String], names: in List[String]): Bool {
  segs.count > 0 and (segs[0] == "Self" or names.contains(segs[0]))
}

func typeArgNamesAny(a: in TypeArg, names: in List[String]): Bool {
  match a {
    case TAType(inner) -> typeExprNamesAny(inner, names)
    case TAValue(e) -> exprNamesAny(e, names)
  }
}

// True when `e` (an array length, a value type argument or a default)
// reads one of `names`.
func exprNamesAny(e: in Expr, names: in List[String]): Bool {
  match e.kind {
    case EPath(path) -> pathNamesAny(path.segments, names)
    case EMember(recv, _) -> exprNamesAny(recv, names)
    case EPrefix(_, inner) -> exprNamesAny(inner, names)
    case EBinop(_, lhs, rhs) -> exprNamesAny(lhs, names) or exprNamesAny(rhs, names)
    case EParen(inner) -> exprNamesAny(inner, names)
    case ECall(fn, args) -> {
      if exprNamesAny(fn, names) {
        return true
      }
      for a in args {
        match a {
          case CANamed(_, v, _) -> if exprNamesAny(v, names) { return true }
          case CAPositional(v) -> if exprNamesAny(v, names) { return true }
        }
      }
      false
    }
    case ETuple(es) -> {
      for x in es {
        if exprNamesAny(x, names) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}
