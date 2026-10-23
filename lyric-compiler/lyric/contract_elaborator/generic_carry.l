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
  "__priv_" + Str.replace(pkgName, ".", "_") + "_" + name
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
  items.add(Item(docComments = template.docComments, annotations = template.annotations, visibility = template.visibility, kind = IFunc(decl = fn), span = template.span))
  SourceFile(
    moduleDoc = None,
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
        case SScope(binding, _) -> match binding {
          case Some(n) -> names.add(n)
          case None -> ()
        }
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

/// The generics `items` (the package `pkgName`) contribute to the packages that call it.
pub func carryPrivateGenerics(items: in List[Item], pkgName: in String): CarriedGenerics {
  val privates: Map[String, FunctionDecl] = newMap()
  val privateItems: Map[String, Item] = newMap()
  val pubs: List[FunctionDecl] = newList()
  val pubItems: List[Item] = newList()
  for it in items {
    match it.kind {
      case IFunc(fn) -> {
        if isGenericFn(fn) and hasBodyFn(fn) {
          if isPubVisibility(fn.visibility) {
            pubs.add(fn)
            pubItems.add(it)
          } else if not hasAnnotation(fn.annotations, "externTarget") {
            privates.put(fn.name, fn)
            privateItems.put(fn.name, it)
          }
        }
      }
      case _ -> ()
    }
  }

  // The private generics reachable from a `pub` generic, to a fixpoint.
  val reached: List[String] = newList()
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
      if privates.containsKey(n) and not shadowed.contains(n) and not reached.contains(n) {
        reached.add(n)
        work.add(mapGetFn(privates, n))
        workItems.add(mapGetItem(privateItems, n))
      }
      // A parameter or local of the same name is a different thing: not a use of the helper.
    }
    wi = wi + 1
  }

  val renames: Map[String, String] = newMap()
  for n in reached {
    renames.put(n, carriedName(pkgName, n))
  }

  val outPub: List[FunctionDecl] = newList()
  var qi = 0
  while qi < pubs.count {
    outPub.add(if reached.count == 0 { pubs[qi] } else { renameCalls(pubs[qi], pubItems[qi], renames) })
    qi = qi + 1
  }
  val outPriv: List[FunctionDecl] = newList()
  for n in reached {
    val fn = mapGetFn(privates, n)
    outPriv.add(renamedDecl(renameCalls(fn, mapGetItem(privateItems, n), renames), carriedName(pkgName, n)))
  }
  CarriedGenerics(pubFuncs = outPub, privateCopies = outPriv)
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
