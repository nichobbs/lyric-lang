//! Carrying the private generic helpers of a `pub` generic across a package boundary (#8427).
//!
//! A generic function's body is compiled into each package that calls it.  A `pub` generic that
//! calls a private generic of its own package therefore needs that helper in the calling package
//! too, but a consumer reaches the library only through public names: a restored dependency is read
//! from contract metadata (which carries `pub` generic bodies), and a private method of another
//! assembly cannot be bound.  Here the helpers a `pub` generic reaches are copied under a name
//! unique to their package (`__priv_<Pkg>_<name>`, so two packages' private `loop[T]` cannot
//! collide in `Lyric.Mono`, which keys imported generics by bare name) and the calls to them in the
//! carried bodies are rewritten to match.  The package's own code is untouched: only the carried
//! copies are renamed.
//!
//! The private non-generic helpers a `pub` generic reaches are copied the same way when a copy is
//! the same function (D273): `plainCopyable` leaves out a helper that mentions module-level state,
//! a private type, a contract clause or a default argument, and one whose name is overloaded.  Those
//! stay unresolved in the consuming package (T0123).
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

/// What a package contributes to its consumers' monomorphiser: its `pub` generics (bodies rewritten
/// to call the carried copies) and the private generics they reach, renamed.
pub record CarriedGenerics {
  pubFuncs: List[FunctionDecl]
  privateCopies: List[FunctionDecl]
}

/// The name a private generic `name` of package `pkgName` is carried under.
pub func carriedName(pkgName: in String, name: in String): String {
  // A helper read back from a restored package already has its carried name.
  if Str.startsWith(name, "__priv_") {
    name
  } else {
    "__priv_" + Str.replace(pkgName, ".", "_") + "_" + name
  }
}

func isPubVisibility(v: in Option[Visibility]): Bool {
  match v {
    case Some(VisPub(_)) -> true
    case _ -> false
  }
}

func isGenericFn(fn: in FunctionDecl): Bool {
  match fn.generics {
    case Some(_) -> true
    case None -> false
  }
}

func hasBodyFn(fn: in FunctionDecl): Bool {
  match fn.body {
    case Some(_) -> true
    case None -> false
  }
}

func hasAnnotation(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if a.name.segments.count > 0 and a.name.segments[a.name.segments.count - 1] == name {
      return true
    }
  }
  false
}

func oneItemFile(fn: in FunctionDecl, template: in Item): SourceFile {
  val items: List[Item] = newList()
  items.add(
    Item(
      docComments = template.docComments,
      annotations = template.annotations,
      visibility = template.visibility,
      kind = IFunc(decl = fn),
      span = template.span
    )
  )
  SourceFile(
    moduleDoc = newList(),
    fileAnnotations = newList(),
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = template.span), span = template.span),
    imports = newList(),
    items = items,
    span = template.span
  )
}

// Every name `fn` binds locally: its parameters, `val`/`var`/`let` and `for` patterns, lambda
// parameters, match-arm patterns and catch bindings.  A name bound here may shadow a helper of the
// same name, so a call to it is not a call to the helper.
func boundNames(fn: in FunctionDecl, template: in Item): List[String] {
  val names: List[String] = newList()
  for p in fn.params {
    names.add(p.name)
  }
  val file = oneItemFile(fn, template)
  mapStmtsInFile(
    file,
    { s: Statement ->
      match s.kind {
        case SLocal(b) -> match b {
          case LBVal(pat, _, _) -> patternNames(pat, names)
          case LBVar(n, _, _) -> names.add(n)
          case LBLet(n, _, _) -> names.add(n)
        }
        case SFor(_, pat, _, _) -> patternNames(pat, names)
        case STry(_, catches, _) -> {
          for c in catches {
            match c.bindName {
              case Some(n) -> names.add(n)
              case None -> ()
            }
          }
        }
        case SScope(binding, _) -> match binding { case Some(n) -> names.add(n); case None -> () }
        case _ -> ()
      }
      s
    }
  )
  anyExprInFile(
    file,
    { e: Expr ->
      match e.kind {
        case ELambda(ps, _) -> {
          for lp in ps {
            names.add(lp.name)
          }
        }
        case EMatch(_, arms) -> {
          for arm in arms {
            patternNames(arm.pattern, names)
          }
        }
        case _ -> ()
      }
      false
    }
  )
  names
}

func patternNames(p: in Pattern, names: in List[String]): Unit {
  match p.kind {
    case PBinding(n, inner) -> {
      names.add(n)
      match inner {
        case Some(i) -> patternNames(i, names)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        patternNames(a, names)
      }
    }
    case PRecord(_, fields, _) -> {
      for f in fields {
        match f {
          case RPFNamed(_, pat, _) -> patternNames(pat, names)
          case RPFShort(n, _) -> names.add(n)
        }
      }
    }
    case PTuple(ps) -> {
      for q in ps {
        patternNames(q, names)
      }
    }
    case PParen(i) -> patternNames(i, names)
    case PTypeTest(i, _) -> patternNames(i, names)
    case POr(ps) -> {
      for q in ps {
        patternNames(q, names)
      }
    }
    case _ -> ()
  }
}

// The single-segment names `fn` mentions as a call target or as a value (`map(xs, helper)`).
func mentionedNames(fn: in FunctionDecl, template: in Item): List[String] {
  val names: List[String] = newList()
  anyExprInFile(
    oneItemFile(fn, template),
    { e: Expr ->
      match e.kind {
        case EPath(path) -> {
          if path.segments.count == 1 and not names.contains(path.segments[0]) {
            names.add(path.segments[0])
          }
        }
        case _ -> ()
      }
      false
    }
  )
  names
}

func renameCalls(fn: in FunctionDecl, template: in Item, renames: in Map[String, String]): FunctionDecl {
  val shadowed = boundNames(fn, template)
  val rewritten = mapExprsInFile(
    oneItemFile(fn, template),
    { e: Expr ->
      match e.kind {
        case EPath(path) -> {
          if path.segments.count == 1 and renames.containsKey(path.segments[0]) and not shadowed.contains(path.segments[0]) {
            val segs: List[String] = newList()
            segs.add(mapGetOr(renames, path.segments[0], path.segments[0]))
            Expr(kind = EPath(path = ModulePath(segments = segs, span = path.span)), span = e.span)
          } else {
            e
          }
        }
        case _ -> e
      }
    }
  )
  match rewritten.items[0].kind {
    case IFunc(d) -> d
    case _ -> fn
  }
}

func mapGetOr(m: in Map[String, String], key: in String, fallback: in String): String {
  match mapGet(m, key) {
    case Some(v) -> v
    case None -> fallback
  }
}

func renamedDecl(fn: in FunctionDecl, newName: in String): FunctionDecl {
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = newName,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
}

// Every name a private non-generic helper must not mention to be copied: the package's private
// module-level values and constants (a copy would hold its own instance of any state they carry),
// and its private types and their case names (the consumer cannot name them).
func forbiddenNames(items: in List[Item]): List[String] {
  val names: List[String] = newList()
  for it in items {
    val isPub = isPubVisibility(it.visibility)
    match it.kind {
      case IVal(v) -> if not isPub { patternNames(v.pattern, names) }
      case IConst(c) -> if not isPub { names.add(c.name) }
      case IRecord(r) -> if not isPub { names.add(r.name) }
      case IExposedRec(r) -> if not isPub { names.add(r.name) }
      case IOpaque(o) -> if not isPub { names.add(o.name) }
      case IProtected(p) -> if not isPub { names.add(p.name) }
      case IInterface(i) -> if not isPub { names.add(i.name) }
      case IDistinctType(d) -> if not isPub { names.add(d.name) }
      case ITypeAlias(a) -> if not isPub { names.add(a.name) }
      case IExternType(e) -> if not isPub { names.add(e.name) }
      case IUnion(u) -> if not isPub { names.add(u.name); for c in u.cases { names.add(c.name) } }
      case IEnum(e) -> if not isPub { names.add(e.name); for c in e.cases { names.add(c.name) } }
      case _ -> ()
    }
  }
  names
}

func pathMentions(p: in ModulePath, names: in List[String]): Bool {
  p.segments.count > 0 and names.contains(p.segments[0])
}

func typeMentions(te: in TypeExpr, names: in List[String]): Bool {
  match te.kind {
    case TRef(p) -> pathMentions(p, names)
    case TGenericApp(h, args) -> {
      if pathMentions(h, names) {
        return true
      }
      for a in args {
        match a {
          case TAType(t) -> if typeMentions(t, names) { return true }
          case TAValue(_) -> ()
        }
      }
      false
    }
    case TArray(_, el) -> typeMentions(el, names)
    case TSlice(el) -> typeMentions(el, names)
    case TRefined(u, _) -> pathMentions(u, names)
    case TTuple(ts) -> {
      for t in ts {
        if typeMentions(t, names) {
          return true
        }
      }
      false
    }
    case TNullable(i) -> typeMentions(i, names)
    case TParen(i) -> typeMentions(i, names)
    case TFunction(ps, r) -> {
      for t in ps {
        if typeMentions(t, names) {
          return true
        }
      }
      typeMentions(r, names)
    }
    case _ -> false
  }
}

func optTypeMentions(t: in Option[TypeExpr], names: in List[String]): Bool {
  match t {
    case Some(x) -> typeMentions(x, names)
    case None -> false
  }
}

func patternMentions(p: in Pattern, names: in List[String]): Bool {
  match p.kind {
    case PConstructor(head, args) -> {
      if pathMentions(head, names) {
        return true
      }
      for a in args {
        if patternMentions(a, names) {
          return true
        }
      }
      false
    }
    case PBinding(_, inner) -> match inner { case Some(i) -> patternMentions(i, names); case None -> false }
    case PRecord(head, fields, _) -> {
      if pathMentions(head, names) {
        return true
      }
      for f in fields {
        match f {
          case RPFNamed(_, pat, _) -> if patternMentions(pat, names) { return true }
          case RPFShort(_, _) -> ()
        }
      }
      false
    }
    case PTuple(ps) -> {
      for q in ps {
        if patternMentions(q, names) {
          return true
        }
      }
      false
    }
    case PParen(i) -> patternMentions(i, names)
    case PTypeTest(i, t) -> patternMentions(i, names) or typeMentions(t, names)
    case POr(ps) -> {
      for q in ps {
        if patternMentions(q, names) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

// True when `fn`, a private non-generic helper, can be copied into the package that specialises a
// `pub` generic reaching it: it has no contract clauses or default arguments (their expressions are
// not rewritten to the carried names), only the annotations that do not change its meaning, and it
// mentions nothing in `forbidden`, in its signature or body, that a local binding does not shadow.
func plainCopyable(fn: in FunctionDecl, template: in Item, forbidden: in List[String]): Bool {
  if fn.contracts.count > 0 {
    return false
  }
  for a in fn.annotations {
    val n = if a.name.segments.count > 0 { a.name.segments[a.name.segments.count - 1] } else { "" }
    if n != "pure" and n != "io" {
      return false
    }
  }
  for p in fn.params {
    match p.dflt {
      case Some(_) -> return false
      case None -> ()
    }
    if typeMentions(p.ty, forbidden) {
      return false
    }
  }
  if optTypeMentions(fn.ret, forbidden) {
    return false
  }
  val shadowed = boundNames(fn, template)
  var bad = false
  val file = oneItemFile(fn, template)
  mapStmtsInFile(
    file,
    { s: Statement ->
      match s.kind {
        case SLocal(b) -> match b {
          case LBVal(pat, ty, _) -> if patternMentions(pat, forbidden) or optTypeMentions(ty, forbidden) {
            bad = true
          }
          case LBVar(_, ty, _) -> if optTypeMentions(ty, forbidden) { bad = true }
          case LBLet(_, ty, _) -> if optTypeMentions(ty, forbidden) { bad = true }
        }
        case SFor(_, pat, _, _) -> if patternMentions(pat, forbidden) { bad = true }
        case _ -> ()
      }
      s
    }
  )
  anyExprInFile(
    file,
    { e: Expr ->
      match e.kind {
        case EPath(path) -> {
          if path.segments.count > 0 and forbidden.contains(path.segments[0]) and not (path.segments.count == 1 and shadowed.contains(path.segments[0])) {
            bad = true
          }
        }
        case ELambda(ps, _) -> {
          for lp in ps {
            if optTypeMentions(lp.ty, forbidden) {
              bad = true
            }
          }
        }
        case EMatch(_, arms) -> {
          for arm in arms {
            if patternMentions(arm.pattern, forbidden) {
              bad = true
            }
          }
        }
        case _ -> ()
      }
      false
    }
  )
  not bad
}

func isPlainCarryCandidate(fn: in FunctionDecl): Bool {
  if isGenericFn(fn) or not hasBodyFn(fn) or fn.name == "main" {
    return false
  }
  if hasAnnotation(fn.annotations, "externTarget") or hasAnnotation(fn.annotations, "axiom") or hasAnnotation(fn.annotations, "test") {
    return false
  }
  // A restored package's copies arrive as `pub` under their carried names.
  not isPubVisibility(fn.visibility) or Str.startsWith(fn.name, "__priv_")
}

/// The generics `items` (the package `pkgName`) contribute to the packages that call it: its `pub`
/// generics, the private generics they reach, and the private non-generic helpers they reach that
/// can be copied (`plainCopyable`).
pub func carryPrivateGenerics(items: in List[Item], pkgName: in String): CarriedGenerics {
  carryWith(items, pkgName, false)
}

/// As `carryPrivateGenerics`, for a package whose generics are all collected as they are (a source
/// dependency of a JVM build): `pubFuncs` holds every generic with a body, none renamed, and
/// `privateCopies` only the private non-generic helpers they reach.
pub func carryPlainHelpersOfGenerics(items: in List[Item], pkgName: in String): CarriedGenerics {
  carryWith(items, pkgName, true)
}

func carryWith(items: in List[Item], pkgName: in String, allGenerics: in Bool): CarriedGenerics {
  val privates: Map[String, FunctionDecl] = newMap()
  val privateItems: Map[String, Item] = newMap()
  val plains: Map[String, FunctionDecl] = newMap()
  val plainItems: Map[String, Item] = newMap()
  val nameCount: Map[String, Int] = newMap()
  val pubs: List[FunctionDecl] = newList()
  val pubItems: List[Item] = newList()
  for it in items {
    match it.kind {
      case IFunc(fn) -> {
        nameCount[fn.name] = 1 + mapGetOr0(nameCount, fn.name)
        if isGenericFn(fn) and hasBodyFn(fn) {
          if allGenerics or isPubVisibility(fn.visibility) {
            pubs.add(fn)
            pubItems.add(it)
          } else if not hasAnnotation(fn.annotations, "externTarget") {
            privates.add(fn.name, fn)
            privateItems.add(fn.name, it)
          }
        } else if isPlainCarryCandidate(fn) and not plains.containsKey(fn.name) {
          plains.add(fn.name, fn)
          plainItems.add(fn.name, it)
        }
      }
      case _ -> ()
    }
  }
  // An overloaded name cannot be told apart by the bare-name calls the rewrite works on.
  for n in mapKeys(plains) {
    if mapGetOr0(nameCount, n) > 1 {
      plains.remove(n)
    }
  }
  if plains.count == 0 and (allGenerics or privates.count == 0) {
    return CarriedGenerics(pubFuncs = pubs, privateCopies = newList())
  }
  val forbidden = if plains.count > 0 { forbiddenNames(items) } else { newList() }

  // The private generics and copyable helpers reachable from a `pub` generic, to a fixpoint.
  val reached: List[String] = newList()
  val reachedPlain: List[String] = newList()
  val declined: List[String] = newList()
  val work: List[FunctionDecl] = newList()
  val workItems: List[Item] = newList()
  var pi = 0
  while pi < pubs.count {
    work.add(pubs[pi])
    workItems.add(pubItems[pi])
    pi = pi + 1
  }
  var wi = 0
  while wi < work.count {
    val shadowed = boundNames(work[wi], workItems[wi])
    for n in mentionedNames(work[wi], workItems[wi]) {
      // A parameter or local of the same name is a different thing: not a use of the helper.
      if not shadowed.contains(n) {
        if privates.containsKey(n) and not reached.contains(n) {
          reached.add(n)
          work.add(mapGetFn(privates, n))
          workItems.add(mapGetItem(privateItems, n))
        } else if plains.containsKey(n) and not reachedPlain.contains(n) and not declined.contains(n) {
          if plainCopyable(mapGetFn(plains, n), mapGetItem(plainItems, n), forbidden) {
            reachedPlain.add(n)
            work.add(mapGetFn(plains, n))
            workItems.add(mapGetItem(plainItems, n))
          } else {
            declined.add(n)
          }
        }
      }
    }
    wi = wi + 1
  }

  val renames: Map[String, String] = newMap()
  for n in reached {
    renames.add(n, carriedName(pkgName, n))
  }
  for n in reachedPlain {
    renames.add(n, carriedName(pkgName, n))
  }

  val outPub: List[FunctionDecl] = newList()
  var qi = 0
  while qi < pubs.count {
    outPub.add(if renames.count == 0 { pubs[qi] } else { renameCalls(pubs[qi], pubItems[qi], renames) })
    qi = qi + 1
  }
  val outPriv: List[FunctionDecl] = newList()
  for n in reached {
    val fn = mapGetFn(privates, n)
    outPriv.add(renamedDecl(renameCalls(fn, mapGetItem(privateItems, n), renames), carriedName(pkgName, n)))
  }
  for n in reachedPlain {
    val fn = mapGetFn(plains, n)
    outPriv.add(renamedDecl(renameCalls(fn, mapGetItem(plainItems, n), renames), carriedName(pkgName, n)))
  }
  CarriedGenerics(pubFuncs = outPub, privateCopies = outPriv)
}

func mapGetOr0(m: in Map[String, Int], key: in String): Int {
  match mapGet(m, key) {
    case Some(v) -> v
    case None -> 0
  }
}

func mapGetFn(m: in Map[String, FunctionDecl], key: in String): FunctionDecl {
  match mapGet(m, key) {
    case Some(v) -> v
    case None -> panic("Lyric.ContractElaborator.carryPrivateGenerics: missing private generic " + key)
  }
}

func mapGetItem(m: in Map[String, Item], key: in String): Item {
  match mapGet(m, key) {
    case Some(v) -> v
    case None -> panic("Lyric.ContractElaborator.carryPrivateGenerics: missing private generic item " + key)
  }
}
