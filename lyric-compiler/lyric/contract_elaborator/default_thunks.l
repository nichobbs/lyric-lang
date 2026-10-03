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
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
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
          added.add(thunkItem(thunk, p.ty, d, sp))
        }
      }
      case None -> ()
    }
  }
}

func thunkItem(name: in String, ty: in TypeExpr, dflt: in Expr, sp: in Span): Item {
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
  val vis: Option[Visibility] = Some(value = VisPub(span = sp))
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
