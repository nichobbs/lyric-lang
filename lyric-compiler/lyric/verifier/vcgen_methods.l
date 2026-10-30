//! verifier/vcgen_methods.l — goals for record and impl methods, inherited interface clauses.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// ─────────────────────────────────────────────────────────────────────────────
// Methods (#8231).
// ─────────────────────────────────────────────────────────────────────────────
// The interface clauses an `impl` method inherits (docs/01 §6.1.1): the
// interface method's `requires:`/`ensures:`, written against its own
// parameter names, matched to the implementing method's by position.
pub record InheritedClauses {
  pub clauses: List[ContractClause]
  pub paramNames: List[String]
}

func noInheritedClauses(): InheritedClauses {
  val noClauses: List[ContractClause] = newList()
  val noNames: List[String] = newList()
  InheritedClauses(clauses = noClauses, paramNames = noNames)
}

// A method of the type a method being verified belongs to: its name and
// declared result, which a call of it on `self` has (#8231).
record SiblingMethod {
  name: String
  ret: Option[TypeExpr]
}

// The methods declared in a record's body.  `self: in Self` is the record
// itself, at its own type parameters.
func goalsForRecordMethods(
  level: in VerificationLevel,
  env0: in VEnv,
  recordName: in String,
  generics: in Option[GenericParams],
  members: in List[RecordMember],
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  val siblings: List[SiblingMethod] = newList()
  for m in members {
    match m {
      case RMFunc(fn) -> siblings.add(SiblingMethod(name = fn.name, ret = fn.ret))
      case _ -> ()
    }
  }
  val fields = SelfFields.recordFieldNames(members)
  val selfType = Some(value = typeOfDeclaration(recordName, generics))
  for m in members {
    match m {
      case RMFunc(fn) -> goalsForMethod(
        level,
        env0,
        recordName,
        fields,
        generics,
        selfType,
        siblings,
        fn,
        Ok(value = noInheritedClauses()),
        allGoals,
        allDiags
      )
      case _ -> ()
    }
  }
}

// The type a declaration `name[generics]` names at its own type parameters:
// `Box[T]` inside `record Box[T]`.
func typeOfDeclaration(name: in String, generics: in Option[GenericParams]): TypeExpr {
  val sp = makeSpan(initialPosition(), initialPosition())
  val segs: List[String] = newList()
  segs.add(name)
  val head = ModulePath(segments = segs, span = sp)
  match generics {
    case None -> TypeExpr(kind = TRef(path = head), span = sp)
    case Some(gp) -> {
      val args: List[TypeArg] = newList()
      for g in gp.params {
        match g {
          case GPType(n, gsp) -> {
            val ps: List[String] = newList()
            ps.add(n)
            args.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = ps, span = gsp)), span = gsp)))
          }
          case GPValue(n, _, gsp) -> {
            val ps: List[String] = newList()
            ps.add(n)
            args.add(TAValue(expr = Expr(kind = EPath(path = ModulePath(segments = ps, span = gsp)), span = gsp)))
          }
        }
      }
      if args.count == 0 {
        TypeExpr(kind = TRef(path = head), span = sp)
      } else {
        TypeExpr(kind = TGenericApp(head = head, args = args), span = sp)
      }
    }
  }
}

// The methods of an `impl` block, each checked against its own clauses and
// the ones it inherits from the interface it implements
// (`resolveImplInterface`).  When the interface cannot be resolved, or it
// declares no method of an implementing method's name and arity, the
// method's inherited obligations cannot be stated: V0033, never "nothing
// inherited".
func goalsForImplMethods(
  level: in VerificationLevel,
  env0: in VEnv,
  file: in SourceFile,
  pscope: in PackageScope,
  decl: in ImplDecl,
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  val siblings: List[SiblingMethod] = newList()
  for m in decl.members {
    match m {
      case IMplFunc(fn) -> siblings.add(SiblingMethod(name = fn.name, ret = fn.ret))
      case _ -> ()
    }
  }
  val ownerName = implTargetName(decl.target)
  val noRecords: List[RecordDecl] = newList()
  val fields = SelfFields.implTargetFieldNames(SelfFields.typeFieldIndex(file, noRecords), decl.target)
  var anyProved = false
  for m in decl.members {
    match m {
      case IMplFunc(fn) -> if vlIsProofRequired(levelOfFunction(level, fn)) { anyProved = true }
      case _ -> ()
    }
  }
  if not anyProved {
    return
  }
  val resolved = resolveImplInterface(file, pscope, decl.iface.head.segments)
  match resolved {
    case Err(why) -> allDiags.add(
      untranslatableDiag(
        "the methods of this `impl` must also satisfy the clauses of the interface they implement, but " +
          why,
        decl.iface.span
      )
    )
    case Ok(_) -> ()
  }
  for m in decl.members {
    match m {
      case IMplFunc(fn) -> {
        val inherited: Result[InheritedClauses, String] = match resolved {
          case Ok(iface) -> inheritedInterfaceClauses(iface, fn)
          // Reported once, at the interface.
          case Err(_) -> Ok(value = noInheritedClauses())
        }
        goalsForMethod(
          level,
          env0,
          ownerName,
          fields,
          decl.generics,
          Some(value = decl.target),
          siblings,
          fn,
          inherited,
          allGoals,
          allDiags
        )
      }
      case _ -> ()
    }
  }
}

// The interface an `impl` names (`segs`), as the type checker resolves it:
// a qualified name `Q.I` in the package `Q` (an import's alias, or a
// package path), a bare name in the proved package — the file and the
// package's other files — and otherwise in the packages it imports and the
// prelude `Std.Core`.  Err with the reason when the name is declared more
// than once where it is looked up, or in a package whose declarations the
// verifier did not read (a dependency restored as a compiled assembly).
func resolveImplInterface(
  file: in SourceFile, pscope: in PackageScope, segs: in List[String]
): Result[InterfaceDecl, String] {
  val shown = joinPathSegments(segs)
  if segs.count == 0 {
    return Err(error = "the interface has no name")
  }
  val ifaceName = segs[segs.count - 1]
  val own = joinPathSegments(file.packageDecl.path.segments)
  val ownCandidates: List[InterfaceDecl] = newList()
  for it in file.items {
    match it.kind {
      case IInterface(d) -> if d.name == ifaceName { ownCandidates.add(d) }
      case _ -> ()
    }
  }
  for d in pscope.siblings.interfaces {
    if d.name == ifaceName {
      ownCandidates.add(d)
    }
  }
  // The packages the name may be declared in, other than the proved one.
  val lookIn: List[String] = newList()
  if segs.count > 1 {
    val qualifier: List[String] = newList()
    var qi = 0
    while qi < segs.count - 1 {
      qualifier.add(segs[qi])
      qi = qi + 1
    }
    val q = joinPathSegments(qualifier)
    var target = q
    for imp in file.imports {
      match imp.asAlias {
        case Some(alias) -> if alias == q and not imp.isExtern { target = joinPathSegments(imp.path.segments) }
        case None -> ()
      }
    }
    if target == own {
      return pickInterface(ownCandidates, shown, "this package")
    }
    lookIn.add(target)
  } else {
    if ownCandidates.count > 0 {
      return pickInterface(ownCandidates, shown, "this package")
    }
    lookIn.add("Std.Core")
    for n in scopeDeclsOfFile(file).imports {
      if not lookIn.contains(n) {
        lookIn.add(n)
      }
    }
    for n in pscope.siblings.imports {
      if not lookIn.contains(n) {
        lookIn.add(n)
      }
    }
  }
  val found: List[InterfaceDecl] = newList()
  val unread: List[String] = newList()
  for pkg in lookIn {
    var read = false
    for p in pscope.imports.packages {
      if p.name == pkg {
        read = true
        for d in p.decls.interfaces {
          if d.name == ifaceName {
            found.add(d)
          }
        }
      }
    }
    if not read and pkg != own {
      unread.add(pkg)
    }
  }
  if found.count == 0 and unread.count > 0 {
    return Err(
      error = "interface `" + shown + "` is declared in a package whose declarations the verifier cannot read (" +
        Str.joinList(", ", unread) +
        "), so it cannot see the interface's `requires:`/`ensures:` clauses"
    )
  }
  if found.count > 1 or (found.count == 1 and unread.count > 0) {
    return Err(error = "interface `" + shown + "` may be declared in more than one of the packages in scope")
  }
  pickInterface(found, shown, "the packages in scope")
}

func pickInterface(found: in List[InterfaceDecl], shown: in String, place: in String): Result[InterfaceDecl, String] {
  if found.count == 1 {
    return Ok(value = found[0])
  }
  if found.count == 0 {
    return Err(error = "interface `" + shown + "` is not declared in " + place)
  }
  Err(error = "interface `" + shown + "` is declared more than once in " + place)
}

// An interface's default methods, verified once for every implementation:
// `Self` is a type of its own, and the interface's other methods are
// reached only through calls the verifier does not interpret.
func goalsForInterfaceDefaults(
  level: in VerificationLevel,
  env0: in VEnv,
  iface: in InterfaceDecl,
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  val siblings: List[SiblingMethod] = newList()
  for m in iface.members {
    match m {
      case IMSig(sig) -> siblings.add(SiblingMethod(name = sig.name, ret = sig.ret))
      case IMFunc(fn) -> siblings.add(SiblingMethod(name = fn.name, ret = fn.ret))
      case IMAssoc(_) -> ()
    }
  }
  val noFields: Map[String, Bool] = newMap()
  for m in iface.members {
    match m {
      case IMFunc(fn) -> if isSome(fn.body) {
        goalsForMethod(
          level,
          env0,
          iface.name,
          noFields,
          iface.generics,
          None,
          siblings,
          fn,
          Ok(value = noInheritedClauses()),
          allGoals,
          allDiags
        )
      }
      case _ -> ()
    }
  }
}

// The clauses `fn` inherits from `iface`'s method of its name, matched to
// its parameters by position.  Err when the interface declares no method of
// that name or arity: the obligations cannot be stated, and assuming none
// would let the method skip them.
func inheritedInterfaceClauses(iface: in InterfaceDecl, fn: in FunctionDecl): Result[InheritedClauses, String] {
  val methods: Map[String, Bool] = newMap()
  for m in iface.members {
    match m {
      case IMSig(sig) -> if not methods.containsKey(sig.name) { methods.add(sig.name, true) }
      case IMFunc(ifn) -> if not methods.containsKey(ifn.name) { methods.add(ifn.name, true) }
      case IMAssoc(_) -> ()
    }
  }
  for m in iface.members {
    match m {
      case IMSig(sig) -> if sig.name == fn.name {
        return clausesInheritedFrom(iface.name, methods, sig.params, sig.contracts, fn)
      }
      case IMFunc(ifn) -> if ifn.name == fn.name {
        return clausesInheritedFrom(iface.name, methods, ifn.params, ifn.contracts, fn)
      }
      case IMAssoc(_) -> ()
    }
  }
  Err(error = "interface `" + iface.name + "` declares no method `" + fn.name + "`")
}

// The interface clauses of a method with `params`, rewritten as the
// implementation reads them: a bare call of one of the interface's
// `methods` is the call on `self` (#8231), and no name is one of the
// implementing type's fields (docs/01 §2.12).
func clausesInheritedFrom(
  ifaceName: in String,
  methods: in Map[String, Bool],
  params: in List[Param],
  contracts: in List[ContractClause],
  fn: in FunctionDecl,
): Result[InheritedClauses, String] {
  if params.count != fn.params.count {
    return Err(
      error = "interface `" + ifaceName + "`'s method `" + fn.name + "` takes " + intToString(params.count) +
        " parameter(s), the implementation " +
        intToString(fn.params.count)
    )
  }
  val names: List[String] = newList()
  for p in params {
    names.add(p.name)
  }
  val noFields: Map[String, Bool] = newMap()
  val clauses: List[ContractClause] = newList()
  for c in contracts {
    match c {
      case CCRequires(x, sp) -> clauses.add(CCRequires(expr = resolveMemberExpr(noFields, methods, params, x), span = sp))
      case CCEnsures(x, sp) -> clauses.add(CCEnsures(expr = resolveMemberExpr(noFields, methods, params, x), span = sp))
      case _ -> ()
    }
  }
  Ok(value = InheritedClauses(clauses = clauses, paramNames = names))
}

// The name of an `impl` target's type, for its methods' goal labels.
func implTargetName(target: in TypeExpr): String {
  match target.kind {
    case TRef(path) -> joinPathSegments(path.segments)
    case TGenericApp(head, _) -> joinPathSegments(head.segments)
    case TParen(inner) -> implTargetName(inner)
    case _ -> "Self"
  }
}

// A method of a type as a function of its own named `name`: bare field and
// sibling-method names in its contracts and body resolved against `self`,
// `Self` replaced by the type, and the type's generic parameters ahead of
// the method's.
func methodAsFunction(
  name: in String,
  fields: in Map[String, Bool],
  typeGenerics: in Option[GenericParams],
  selfType: in Option[TypeExpr],
  siblings: in List[SiblingMethod],
  fn: in FunctionDecl,
): FunctionDecl {
  val noCases: Map[String, Bool] = newMap()
  val methods: Map[String, Bool] = newMap()
  for sm in siblings {
    if not methods.containsKey(sm.name) {
      methods.add(sm.name, true)
    }
  }
  val body = match fn.body {
    case Some(b) -> Some(value = SelfFields.resolveSelfMembersInBody(fields, methods, noCases, fn.params, b))
    case None -> None
  }
  val contracts: List[ContractClause] = newList()
  for c in fn.contracts {
    match c {
      case CCRequires(x, sp) -> contracts.add(
        CCRequires(expr = resolveMemberExpr(fields, methods, fn.params, x), span = sp)
      )
      case CCEnsures(x, sp) -> contracts.add(
        CCEnsures(expr = resolveMemberExpr(fields, methods, fn.params, x), span = sp)
      )
      case other -> contracts.add(other)
    }
  }
  val params: List[Param] = newList()
  for p in fn.params {
    params.add(match selfType { case Some(st) -> p.copy(ty = substSelfType(p.ty, st)); case None -> p })
  }
  val ret = match fn.ret {
    case Some(te) -> match selfType {
      case Some(st) -> Some(value = substSelfType(te, st))
      case None -> Some(value = te)
    }
    case None -> None
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = name,
    generics = mergeGenerics(typeGenerics, fn.generics),
    params = params,
    ret = ret,
    whereClause = fn.whereClause,
    contracts = contracts,
    body = body,
    span = fn.span
  )
}

// Verify the method `fn` of the type `owner`: its body and own clauses with
// every bare reference to one of `fields` read as `self.<field>`, as the
// type checker and the backends read it (`Lyric.SelfFields`, #8264); the
// type's parameters `typeGenerics` in scope beside the method's own; `Self`
// read as `selfType` when it is known (an `impl` target); a bare call of a
// sibling method (`methodNames`) read as the call on `self` it is, which the
// verifier does not interpret (a method's contract is not yet used at its
// calls, #8110); and the `inherited` interface clauses checked beside its
// own.  Goals are labelled `<owner>.<method>`.
func goalsForMethod(
  level: in VerificationLevel,
  env0: in VEnv,
  owner: in String,
  fields: in Map[String, Bool],
  typeGenerics: in Option[GenericParams],
  selfType: in Option[TypeExpr],
  siblings: in List[SiblingMethod],
  fn: in FunctionDecl,
  inherited: in Result[InheritedClauses, String],
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  if not vlIsProofRequired(levelOfFunction(level, fn)) {
    return
  }
  val inheritedClauses = match inherited {
    case Ok(ic) -> ic
    case Err(why) -> {
      allDiags.add(untranslatableDiag("the clauses this method inherits from the interface it implements: " + why, fn.span))
      noInheritedClauses()
    }
  }
  val method = methodAsFunction(owner + "." + fn.name, fields, typeGenerics, selfType, siblings, fn)
  // A call of a sibling method on `self` has the sibling's declared result
  // type; it is otherwise not interpreted.
  val distincts: Map[String, TypeExpr] = newMap()
  for k in mapKeys(env0.distincts) {
    match mapGet(env0.distincts, k) {
      case Some(te) -> distincts.add(k, te)
      case None -> ()
    }
  }
  for sm in siblings {
    match sm.ret {
      case Some(te) -> {
        val key = selfMethodResultKey(sm.name)
        if not distincts.containsKey(key) {
          distincts.add(key, match selfType { case Some(st) -> substSelfType(te, st); case None -> te })
        }
      }
      case None -> ()
    }
  }
  val fnEnv = freshSymbolsEnv(envWithDistincts(env0, distincts))
  val noHyps: List[Term] = newList()
  val noState: List[String] = newList()
  val (goals, diags) = goalsForFunctionInheriting(fnEnv, method, noHyps, noState, inheritedClauses)
  for g in goals {
    allGoals.add(g)
  }
  appendTermList2(allDiags, diags)
}

// The key under which a method's environment records the declared result
// type of a sibling method `name`, for a call of it on `self`.
func selfMethodResultKey(name: in String): String {
  "!selfmethod!" + name
}

// `x`, a clause of a member with `params`, with each bare reference to one of
// `fields` written `self.<field>` and each bare call of one of `methods`
// written as a call on `self`, as in the member's body.
func resolveMemberExpr(
  fields: in Map[String, Bool], methods: in Map[String, Bool], params: in List[Param], x: in Expr
): Expr {
  val noCases: Map[String, Bool] = newMap()
  match SelfFields.resolveSelfMembersInBody(fields, methods, noCases, params, FBExpr(expr = x)) {
    case FBExpr(r) -> r
    case FBBlock(_) -> x
  }
}

// A type's generic parameters followed by its method's own.
func mergeGenerics(outer: in Option[GenericParams], inner: in Option[GenericParams]): Option[GenericParams] {
  match outer {
    case None -> inner
    case Some(o) -> match inner {
      case None -> outer
      case Some(n) -> {
        val all: List[GenericParam] = newList()
        for gp in o.params {
          all.add(gp)
        }
        for gp in n.params {
          all.add(gp)
        }
        Some(value = n.copy(params = all))
      }
    }
  }
}

// `te` with every `Self` replaced by `target`.
func substSelfType(te: in TypeExpr, target: in TypeExpr): TypeExpr {
  match te.kind {
    case TSelf -> target
    case TGenericApp(head, args) -> {
      val newArgs: List[TypeArg] = newList()
      for a in args {
        newArgs.add(match a { case TAType(t) -> TAType(ty = substSelfType(t, target)); case other -> other })
      }
      te.copy(kind = TGenericApp(head = head, args = newArgs))
    }
    case TArray(size, elt) -> te.copy(kind = TArray(size = size, element = substSelfType(elt, target)))
    case TSlice(elt) -> te.copy(kind = TSlice(element = substSelfType(elt, target)))
    case TTuple(tys) -> {
      val newTys: List[TypeExpr] = newList()
      for t in tys {
        newTys.add(substSelfType(t, target))
      }
      te.copy(kind = TTuple(types = newTys))
    }
    case TNullable(inner) -> te.copy(kind = TNullable(inner = substSelfType(inner, target)))
    case TFunction(ps, r) -> {
      val newPs: List[TypeExpr] = newList()
      for t in ps {
        newPs.add(substSelfType(t, target))
      }
      te.copy(kind = TFunction(parameters = newPs, retTy = substSelfType(r, target)))
    }
    case TParen(inner) -> te.copy(kind = TParen(inner = substSelfType(inner, target)))
    case _ -> te
  }
}
