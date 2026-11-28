//! impl_defaults.l — inherit interface default methods into `impl` blocks
//! that don't override them (#6433).
//!
//! docs/01-language-reference.md §2.12 states plainly "Interfaces support
//! default methods" and that "[m]ultiple inheritance of interfaces is
//! permitted; diamond conflicts are resolved by requiring explicit
//! override" — text that only makes sense if a default method's body is
//! actually inherited by a conforming `impl` that doesn't re-declare it.
//! `docs/grammar.ebnf`'s `InterfaceMember` production tags `FunctionDecl`
//! explicitly as `(* default method *)`.  Before this pass, an `impl` that
//! omitted a bodied interface member (`IMFunc`) TYPE-CHECKED (
//! `checkImplConformance` only requires abstract `IMSig` members) but had
//! no method at all for the omitted name once compiled: calling it through
//! the concrete record crashed at runtime on both targets (JVM
//! `NoSuchMethodError`, MSIL "unsupported method" — #6433's repro).
//!
//! The fix is a pre-typecheck `SourceFile -> SourceFile` AST rewrite,
//! mirroring `Lyric.Stubbable`'s shape: for every `impl Iface for Target`
//! in the file, for every `IMFunc` member of `Iface` (also declared in
//! this file — see the scope note below) that the impl does not already
//! provide, append a verbatim copy of the interface method's
//! `FunctionDecl` as a new `IMplFunc` impl member, marked with the reserved
//! `__lyric_inherited_default` annotation (the body was written against the
//! interface, so the target's fields are not in its scope: a bare name in it
//! never means one of them, #8264). No `Self` substitution
//! is needed in the synthesis itself: the copied member becomes a real
//! part of the `impl` block, so the EXISTING per-impl `Self` resolution
//! machinery (`registerParamsMsil`'s `selfTypeName` threading, D-progress-
//! 751/753/755) narrows `Self` to the impl's own target type exactly as it
//! does for a hand-written impl method — zero new backend codegen.  An
//! impl that DOES override a default wins outright (no double-registration,
//! checked by name via `implProvidesMethod`).
//!
//! Scope (matching `Lyric.Stubbable`'s own accepted same-file limitation):
//! this pass only sees interfaces declared IN THE SAME FILE as the `impl`.
//! An `impl` of a default-method-bearing interface imported from another
//! package still relies on that interface's own DIM (interface-typed
//! dispatch) path today; cross-package default-method inheritance into a
//! concrete-type call site is a tracked follow-up, not a regression this
//! pass introduces (the crash for that shape is pre-existing and unchanged).
//!
//! Wired into `Lyric.Pipeline.pipeExpandAndRewrite`, after
//! `Lyric.Stubbable`'s own synthesis (so a `@stubbable` interface's
//! synthesized `<Iface>Stub` impl also inherits any default methods) and
//! before `Lyric.Weaver.injectWeaveImports`.
package Lyric.ImplDefaults

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Mono
import Lyric.Expand as Expand
import Lyric.SelfFields as SelfFields

// Last segment of the impl's interface reference — the bare interface name,
// matching how `checkImplConformance` resolves `ifaceName`.
func implIfaceName(decl: in ImplDecl): String {
  val segs = decl.iface.head.segments
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

// True if the impl already declares a member named `name` (an override, or
// an implementation of an abstract `IMSig` member sharing the name).
func implProvidesMethod(decl: in ImplDecl, name: in String): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        if fn.name == name {
          return true
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

// Find an `IInterface` item declared in `items` whose name matches `name`.
// A generic interface is found too: the copy of its default method has the
// interface's parameters replaced by the impl's arguments
// (`inheritedCopy`, #7791).
func findLocalInterface(items: in List[Item], name: in String): Option[InterfaceDecl] {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IInterface(id) -> {
        if id.name == name {
          return Some(value = id)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// Last segment of the impl's TARGET type reference — the bare target name,
// used to key the target-level method namespace for diamond-conflict
// detection (#6447); a generic target (`impl[T] I for Box[T]`, #7704) keys
// by its head, since every instantiation shares the one set of methods.  Any
// other target shape yields "" and opts out of conflict tracking (nothing is
// synthesized for it anyway unless its interface resolves).
func implTargetName(decl: in ImplDecl): String {
  val segs: List[String] = match decl.target.kind {
    case TRef(path) -> path.segments
    case TGenericApp(head, _) -> head.segments
    case _ -> newList()
  }
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

// The interface's default method `fn` as the impl inherits it: verbatim for a
// non-generic interface, with the interface's type parameters replaced by the
// impl's interface arguments for a generic one (`impl Named[Int] for L` gets
// `tagged(x: in Int)` from `tagged(x: in T)`, #7791).  Unchanged when the
// arguments are not all types or their count differs (the checker reports it).
func inheritedCopy(decl: in ImplDecl, ifaceDecl: in InterfaceDecl, fn: in FunctionDecl): FunctionDecl {
  val names: List[String] = newList()
  match ifaceDecl.generics {
    case Some(gp) -> {
      for g in gp.params {
        match g {
          case GPType(name, _) -> names.add(name)
          case GPValue(_, _, _) -> ()
        }
      }
    }
    case None -> ()
  }
  if names.count == 0 {
    return fn
  }
  val args: List[TypeExpr] = newList()
  for a in decl.iface.args {
    match a {
      case TAType(te) -> args.add(te)
      case TAValue(_) -> return fn
    }
  }
  substGenericsInDecl(fn, names, args)
}

// Return `decl` with a verbatim `IMplFunc` copy appended for every `IMFunc`
// default method of `ifaceDecl` that `decl` doesn't already provide AND
// whose name is not blocked by the target-level rules (#6447):
//   * `overridden` — the name is hand-written in SOME impl block for this
//     target (this one or a sibling): the explicit override is the spec's
//     diamond resolution, so no copy is synthesized anywhere for it.
//   * `conflicted` — the name would be synthesized from two or more
//     different interfaces onto this target with no override anywhere:
//     the T0117 diagnostic fires (once, in `inheritDefaultsFile`) and no
//     copy is synthesized, so the backends never see a duplicate member.
// Returns `decl` unchanged (same identity semantics) when nothing needed
// inheriting, so callers can skip rebuilding the enclosing item.
func withInheritedDefaults(
  decl: in ImplDecl,
  ifaceDecl: in InterfaceDecl,
  overridden: in Map[String, Bool],
  conflicted: in Map[String, Bool],
): ImplDecl {
  val targetName = implTargetName(decl)
  var changed = false
  val newMembers: List[ImplMember] = newList()
  var i = 0
  while i < decl.members.count {
    newMembers.add(decl.members[i])
    i = i + 1
  }
  i = 0
  while i < ifaceDecl.members.count {
    match ifaceDecl.members[i] {
      case IMFunc(fn) -> {
        val nsKey = targetName + "/" + fn.name
        val blocked = overridden.containsKey(nsKey) or conflicted.containsKey(nsKey)
        if not implProvidesMethod(decl, fn.name) and not blocked {
          // Marked, so the target's fields stay out of the copy's scope
          // (`inheritedDefaultAnnotationName`, #8264).
          val marked = withMarkerAnnotation(fn.annotations, inheritedDefaultAnnotationName(), fn.span)
          // The copy keeps the interface member's body but not its span: member lookups match a signature by span, and
          // two members of one span (the interface's and this copy) are one to them (#9454).
          val copySpan = Span(startPos = decl.span.startPos, endPos = fn.span.endPos)
          newMembers.add(IMplFunc(fn = inheritedCopy(decl, ifaceDecl, fn).copy(annotations = marked, span = copySpan)))
          changed = true
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  if not changed {
    decl
  } else {
    ImplDecl(
      generics = decl.generics,
      iface = decl.iface,
      target = decl.target,
      whereClause = decl.whereClause,
      members = newMembers,
      span = decl.span
    )
  }
}

// Pre-scan every `IImpl` in `items`, building the two target-level maps the
// synthesis consults (#6447), and emitting a `T0117` diagnostic per
// unresolved diamond conflict:
//   * `overridden`:  `<Target>/<name>` for every HAND-WRITTEN impl member
//     across all impl blocks (the spec's "explicit override" resolution —
//     an override in ANY impl of the target claims the name for the whole
//     target method namespace).
//   * `conflicted`:  `<Target>/<name>` where two or more DIFFERENT
//     same-file interfaces would each synthesize a default of that name
//     onto the target with no override anywhere — docs/01 §2.12's diamond
//     case, which "is resolved by requiring explicit override".  Without
//     this check the pass would synthesize two same-named members onto one
//     target and the BACKENDS would crash on the duplicate (#6447 review).
func collectTargetNamespace(
  items: in List[Item],
  overridden: in Map[String, Bool],
  conflicted: in Map[String, Bool],
  diags: in List[Diagnostic],
): Unit {
  // First pass: hand-written members claim their names.
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(decl) -> {
        val tn = implTargetName(decl)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> {
              val k = tn + "/" + fn.name
              if not overridden.containsKey(k) {
                overridden.add(k, true)
              }
            }
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
  // Second pass: for every un-overridden target/name, accumulate the FULL
  // ordered list of distinct default-supplying interfaces (not just the
  // first two) — a 3+-way diamond needs every supplier's name known before
  // the diagnostic is composed, so "and N more" (#6445 rider) can count the
  // suppliers beyond the two named explicitly.  `conflictOrder` remembers
  // each key the first time it becomes conflicted (its second supplier),
  // preserving the diagnostic's discovery-order position; the diagnostic
  // itself is only ever composed once, after the full scan, from the final
  // supplier list.
  val suppliers: Map[String, List[String]] = newMap()
  val conflictOrder: List[String] = newList()
  val conflictSpans: Map[String, Span] = newMap()
  val conflictTargets: Map[String, String] = newMap()
  val conflictMethods: Map[String, String] = newMap()
  i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(decl) -> {
        val tn = implTargetName(decl)
        match findLocalInterface(items, implIfaceName(decl)) {
          case Some(ifaceDecl) -> {
            var fi = 0
            while fi < ifaceDecl.members.count {
              match ifaceDecl.members[fi] {
                case IMFunc(fn) -> {
                  val k = tn + "/" + fn.name
                  if not overridden.containsKey(k) {
                    val supplierList = match mapGet(suppliers, k) {
                      case Some(l) -> l
                      case None -> {
                        val nl: List[String] = newList()
                        suppliers.add(k, nl)
                        nl
                      }
                    }
                    if not listContains(supplierList, ifaceDecl.name) {
                      supplierList.add(ifaceDecl.name)
                      if supplierList.count == 2 {
                        conflicted.add(k, true)
                        conflictOrder.add(k)
                        conflictSpans.add(k, items[i].span)
                        conflictTargets.add(k, tn)
                        conflictMethods.add(k, fn.name)
                      }
                    }
                  }
                }
                case _ -> {
                }
              }
              fi = fi + 1
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
  // Emit one T0117 per conflicted key, now that every supplier is known.
  var ci = 0
  while ci < conflictOrder.count {
    val k = conflictOrder[ci]
    val names: List[String] = match mapGet(suppliers, k) { case Some(l) -> l; case None -> newList() }
    val tn = match mapGet(conflictTargets, k) { case Some(v) -> v; case None -> "" }
    val mname = match mapGet(conflictMethods, k) { case Some(v) -> v; case None -> "" }
    val span = match mapGet(conflictSpans, k) { case Some(s) -> s; case None -> items[0].span }
    val extraCount = names.count - 2
    val suffix = if extraCount > 0 { " and " + toString(extraCount) + " more" } else { "" }
    diags.add(
      errorDiagnostic(
        "T0117",
        "diamond conflict: interfaces '" + names[0] + "' and '" + names[1] + "'" + suffix +
          " both provide a default method '" +
          mname +
          "' for '" +
          tn +
          "'; resolve by overriding '" +
          mname +
          "' explicitly in an impl block",
        span
      )
    )
    ci = ci + 1
  }
}

// Rewrite every `IImpl` item in `items`, inheriting default methods from a
// same-file interface declaration where applicable. Items that are not
// `IImpl`, or whose interface isn't declared in this file (cross-package —
// see the module doc's scope note), pass through unchanged.
func synthesiseItems(
  items: in List[Item], overridden: in Map[String, Bool], conflicted: in Map[String, Bool]
): List[Item] {
  val result: List[Item] = newList()
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IImpl(decl) -> {
        match findLocalInterface(items, implIfaceName(decl)) {
          case Some(ifaceDecl) -> {
            val newDecl = withInheritedDefaults(decl, ifaceDecl, overridden, conflicted)
            result.add(
              Item(
                docComments = it.docComments,
                annotations = it.annotations,
                visibility = it.visibility,
                kind = IImpl(decl = newDecl),
                span = it.span
              )
            )
          }
          case None -> result.add(it)
        }
      }
      case _ -> result.add(it)
    }
    i = i + 1
  }
  result
}

// Return `file` with every same-file `impl` block's omitted interface
// default methods inherited as real impl members (#6433).
pub record ImplDefaultsResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

pub func inheritDefaultsFile(file: in SourceFile): ImplDefaultsResult {
  val overridden: Map[String, Bool] = newMap()
  val conflicted: Map[String, Bool] = newMap()
  val diags: List[Diagnostic] = newList()
  collectTargetNamespace(file.items, overridden, conflicted, diags)
  val rewritten = SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = synthesiseItems(file.items, overridden, conflicted),
    span = file.span
  )
  ImplDefaultsResult(file = rewritten, diagnostics = diags)
}

// ─────────────────────────────────────────────────────────────────────────────
// Default methods of another package's interface (`--target native`, #9451).
//
// dotnet and the JVM dispatch a default method that an impl omits on the interface's own method (a default
// interface method).  Native has no such thing: every vtable slot names a function of the impl, so an impl of
// another package's interface needs a function for each default it omits.  The interface's body cannot simply be
// copied into the impl, since its names resolve in the declaring package and the impl's package imports something
// else.  Instead the declaring package gets one free function per needed default,
// `__lyric_default_<Interface>_<method>[<interface parameters>](self: in <Interface>, ...)`, whose body is the
// default's own, type-checked in its own scope with each bare call of an interface method written `self.m(...)`,
// and the impl gets a member that calls it with `self`, which is the same dispatch a default interface method
// makes: the body runs on the interface value, and a call it makes on the interface goes through the vtable back
// to the impl.  Runs over every package of the build, so it needs their sources, which a native build has.
// A default it cannot express this way (async, a `Self` in a parameter or result, an `out`/`inout` parameter, its
// own type parameters) is left for the native backend's `N0106`.
// ─────────────────────────────────────────────────────────────────────────────
/// The reserved name of the free function that holds the default method `method` of interface `ifaceName`.
pub func crossDefaultFnName(ifaceName: in String, method: in String): String {
  "__lyric_default_" + ifaceName + "_" + method
}

record CrossIface {
  pkg: String
  decl: InterfaceDecl
  span: Span
}

func crossPkgName(file: in SourceFile): String {
  modulePathJoin(file.packageDecl.path.segments)
}

func crossArgsMentionSelf(args: in List[TypeArg]): Bool {
  for a in args {
    match a {
      case TAType(t) -> if crossTypeMentionsSelf(t) { return true }
      case TAValue(_) -> ()
    }
  }
  false
}

func crossTypeMentionsSelf(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TRef(_) -> false
    case TUnit -> false
    case TNever -> false
    case TGenericApp(_, args) -> crossArgsMentionSelf(args)
    case TArray(sz, el) -> {
      val szs: List[TypeArg] = newList()
      szs.add(sz)
      crossArgsMentionSelf(szs) or crossTypeMentionsSelf(el)
    }
    case TSlice(el) -> crossTypeMentionsSelf(el)
    case TNullable(inner) -> crossTypeMentionsSelf(inner)
    case TParen(inner) -> crossTypeMentionsSelf(inner)
    case TTuple(ts) -> {
      for t in ts {
        if crossTypeMentionsSelf(t) {
          return true
        }
      }
      false
    }
    case TFunction(ps, r) -> {
      for t in ps {
        if crossTypeMentionsSelf(t) {
          return true
        }
      }
      crossTypeMentionsSelf(r)
    }
    case _ -> true
  }
}

func crossHasSelfParam(fn: in FunctionDecl): Bool {
  fn.params.count > 0 and fn.params[0].name == "self"
}

/// The parameters after `self`.
func crossRestParams(fn: in FunctionDecl): List[Param] {
  val rest: List[Param] = newList()
  var i = if crossHasSelfParam(fn) { 1 } else { 0 }
  while i < fn.params.count {
    rest.add(fn.params[i])
    i = i + 1
  }
  rest
}

/// Whether the default `fn` can be held by a free function over the interface type and called from an impl
/// member (both sides of the rewrite agree on this).
func crossEligible(fn: in FunctionDecl): Bool {
  if fn.isAsync or fn.body.isNone() {
    return false
  }
  match fn.generics {
    case Some(_) -> return false
    case None -> ()
  }
  for p in crossRestParams(fn) {
    match p.mode {
      case PMIn -> ()
      case _ -> return false
    }
    if p.dflt.isSome() or crossTypeMentionsSelf(p.ty) {
      return false
    }
  }
  match fn.ret {
    case Some(r) -> if crossTypeMentionsSelf(r) { return false }
    case None -> ()
  }
  true
}

/// The interface `decl` implements when it is declared in another package of the build and named the way the
/// file's imports make resolvable: bare through a plain `import Pkg`, or through the alias or package path it is
/// written with.  `None` leaves the impl alone.
func crossResolveIface(file: in SourceFile, decl: in ImplDecl, ifaces: in Map[String, CrossIface]): Option[CrossIface] {
  val segs = decl.iface.head.segments
  val here = crossPkgName(file)
  if segs.count == 0 {
    return None
  }
  val name = segs[segs.count - 1]
  var found: Option[CrossIface] = None
  var hits = 0
  if segs.count == 1 {
    for imp in file.imports {
      if imp.asAlias.isNone() and imp.selector.isNone() and not imp.isExtern {
        match mapGet(ifaces, modulePathJoin(imp.path.segments) + "." + name) {
          case Some(ci) -> if ci.pkg != here { found = Some(value = ci); hits = hits + 1 }
          case None -> ()
        }
      }
    }
  } else {
    val prefix: List[String] = newList()
    var i = 0
    while i < segs.count - 1 {
      prefix.add(segs[i])
      i = i + 1
    }
    val written = modulePathJoin(prefix)
    for imp in file.imports {
      if not imp.isExtern and imp.selector.isNone() {
        val viaAlias = match imp.asAlias { case Some(a) -> a == written; case None -> false }
        val viaPath = imp.asAlias.isNone() and modulePathJoin(imp.path.segments) == written
        if viaAlias or viaPath {
          match mapGet(ifaces, modulePathJoin(imp.path.segments) + "." + name) {
            case Some(ci) -> if ci.pkg != here { found = Some(value = ci); hits = hits + 1 }
            case None -> ()
          }
        }
      }
    }
  }
  if hits == 1 {
    found
  } else {
    None
  }
}

/// A type argument as the index expression the parser reads an explicit type application from
/// (`f[Int](x)` is `ECall(EIndex(f, [Int]), ...)`); `None` for a type with no such spelling (a tuple, a function).
func crossTypeArgExpr(te: in TypeExpr): Option[Expr] {
  match te.kind {
    case TRef(path) -> Some(value = Expr(kind = EPath(path = path), span = te.span))
    case TParen(inner) -> crossTypeArgExpr(inner)
    case TGenericApp(head, args) -> {
      val idx: List[Expr] = newList()
      for a in args {
        match a {
          case TAType(t) -> match crossTypeArgExpr(t) { case Some(e) -> idx.add(e); case None -> return None }
          case TAValue(e) -> idx.add(e)
        }
      }
      Some(
        value = Expr(
          kind = EIndex(receiver = Expr(kind = EPath(path = head), span = te.span), indices = idx),
          span = te.span
        )
      )
    }
    case _ -> None
  }
}

/// The impl member that runs the default `fn` of `ifaceDecl` for `decl` by calling its free function.
func crossTrampoline(
  decl: in ImplDecl, ifaceDecl: in InterfaceDecl, fn: in FunctionDecl, calleeSegs: in List[String]
): Option[FunctionDecl] {
  // A span of its own, as an inherited copy has (#9454): member lookups match a signature by span, and the
  // interface member's span is not this member's.
  val sp = Span(startPos = decl.span.startPos, endPos = fn.span.endPos)
  val inherited = inheritedCopy(decl, ifaceDecl, fn)
  val params: List[Param] = newList()
  params.add(
    Param(
      mode = PMIn,
      modeExplicit = true,
      name = "self",
      ty = TypeExpr(kind = TSelf, span = sp),
      dflt = None,
      annotations = newList(),
      span = sp
    )
  )
  val callArgs: List[CallArg] = newList()
  callArgs.add(CAPositional(expr = Expr(kind = ESelf, span = sp)))
  for p in crossRestParams(inherited) {
    params.add(p)
    val segs: List[String] = newList()
    segs.add(p.name)
    callArgs.add(CAPositional(expr = Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)))
  }
  val callee0 = Expr(kind = EPath(path = ModulePath(segments = calleeSegs, span = sp)), span = sp)
  val typeIdx: List[Expr] = newList()
  for a in decl.iface.args {
    match a {
      case TAType(t) -> match crossTypeArgExpr(t) { case Some(e) -> typeIdx.add(e); case None -> return None }
      case TAValue(_) -> return None
    }
  }
  val callee = if typeIdx.count > 0 {
    Expr(kind = EIndex(receiver = callee0, indices = typeIdx), span = sp)
  } else {
    callee0
  }
  val call = Expr(kind = ECall(fn = callee, args = callArgs), span = sp)
  Some(
    value = FunctionDecl(
      docComments = newList(),
      annotations = withMarkerAnnotation(newList(), inheritedDefaultAnnotationName(), sp),
      visibility = None,
      isAsync = false,
      name = fn.name,
      generics = None,
      params = params,
      ret = inherited.ret,
      whereClause = None,
      contracts = newList(),
      body = Some(value = FBExpr(expr = call)),
      span = sp
    )
  )
}

/// The free function that holds the default `fn` of `ifaceDecl`: generic over the interface's parameters, taking
/// the interface value as `self`, with each bare call of an interface method written as a call on it.
func crossDefaultFn(ifaceDecl: in InterfaceDecl, fn: in FunctionDecl): FunctionDecl {
  val sp = fn.span
  val ifacePath: List[String] = newList()
  ifacePath.add(ifaceDecl.name)
  val targs: List[TypeArg] = newList()
  match ifaceDecl.generics {
    case Some(gp) -> {
      for g in gp.params {
        match g {
          case GPType(n, gsp) -> {
            val ns: List[String] = newList()
            ns.add(n)
            targs.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = ns, span = gsp)), span = gsp)))
          }
          case GPValue(_, _, _) -> ()
        }
      }
    }
    case None -> ()
  }
  val ifaceTy = if targs.count > 0 {
    TypeExpr(kind = TGenericApp(head = ModulePath(segments = ifacePath, span = sp), args = targs), span = sp)
  } else {
    TypeExpr(kind = TRef(path = ModulePath(segments = ifacePath, span = sp)), span = sp)
  }
  val names: List[String] = newList()
  names.add("Self")
  val tys: List[TypeExpr] = newList()
  tys.add(ifaceTy)
  val sub = substGenericsInDecl(fn, names, tys)
  val params: List[Param] = newList()
  params.add(
    Param(
      mode = PMIn,
      modeExplicit = true,
      name = "self",
      ty = ifaceTy,
      dflt = None,
      annotations = newList(),
      span = sp
    )
  )
  for p in crossRestParams(sub) {
    params.add(p)
  }
  val methods: Map[String, Bool] = newMap()
  for m in ifaceDecl.members {
    match m {
      case IMSig(sig) -> methods.add(sig.name, true)
      case IMFunc(f) -> methods.add(f.name, true)
      case _ -> ()
    }
  }
  val noFields: Map[String, Bool] = newMap()
  val noCases: Map[String, Bool] = newMap()
  val body = match sub.body {
    case Some(b) -> Some(value = SelfFields.resolveSelfMembersInBody(noFields, methods, noCases, params, b))
    case None -> None
  }
  FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility = Some(value = VisPub(span = sp)),
    isAsync = false,
    name = crossDefaultFnName(ifaceDecl.name, fn.name),
    generics = ifaceDecl.generics,
    params = params,
    ret = sub.ret,
    whereClause = ifaceDecl.whereClause,
    contracts = sub.contracts,
    body = body,
    span = sp
  )
}

/// `file` with each impl of another package's interface given a member for every default it omits (recording the
/// default in `needs`, keyed `<Pkg>.<Interface>`).
func crossRewriteConsumer(
  file: in SourceFile, ifaces: in Map[String, CrossIface], needs: in Map[String, List[String]]
): SourceFile {
  val overridden: Map[String, Bool] = newMap()
  val conflicted: Map[String, Bool] = newMap()
  val scratch: List[Diagnostic] = newList()
  collectTargetNamespace(file.items, overridden, conflicted, scratch)
  val base = Expand.generatedSpanBase(file)
  val origins: Map[String, Span] = newMap()
  val items: List[Item] = newList()
  var changed = false
  for it in file.items {
    match it.kind {
      case IImpl(decl) -> match crossResolveIface(file, decl, ifaces) {
        case Some(ci) -> {
          val calleeSegs: List[String] = newList()
          val head = decl.iface.head.segments
          var hi = 0
          while hi < head.count - 1 {
            calleeSegs.add(head[hi])
            hi = hi + 1
          }
          val members: List[ImplMember] = newList()
          for m in decl.members {
            members.add(m)
          }
          val added: List[ImplMember] = newList()
          val tn = implTargetName(decl)
          for im in ci.decl.members {
            match im {
              case IMFunc(fn) -> {
                val blocked = overridden.containsKey(tn + "/" + fn.name)
                if crossEligible(fn) and not implProvidesMethod(decl, fn.name) and not blocked {
                  val segs: List[String] = newList()
                  for c in calleeSegs {
                    segs.add(c)
                  }
                  segs.add(crossDefaultFnName(ci.decl.name, fn.name))
                  match crossTrampoline(decl, ci.decl, fn, segs) {
                    case Some(tramp) -> {
                      added.add(IMplFunc(fn = tramp))
                      val key = ci.pkg + "." + ci.decl.name
                      match mapGet(needs, key) {
                        case Some(l) -> if not listContains(l, fn.name) { l.add(fn.name) }
                        case None -> {
                          val l: List[String] = newList()
                          l.add(fn.name)
                          needs.add(key, l)
                        }
                      }
                    }
                    case None -> ()
                  }
                }
              }
              case _ -> ()
            }
          }
          if added.count == 0 {
            items.add(it)
          } else {
            // Fresh spans of their own: the checker keys a call's resolved callee by its span.
            val probe = ImplDecl(
              generics = decl.generics,
              iface = decl.iface,
              target = decl.target,
              whereClause = decl.whereClause,
              members = added,
              span = decl.span
            )
            val batch: List[Item] = newList()
            batch.add(
              Item(
                docComments = newList(),
                annotations = newList(),
                visibility = None,
                kind = IImpl(decl = probe),
                span = it.span
              )
            )
            for g in Expand.respanGenerated(file, batch, base, it.span, origins) {
              match g.kind {
                case IImpl(gd) -> {
                  for gm in gd.members {
                    members.add(gm)
                  }
                }
                case _ -> ()
              }
            }
            items.add(
              Item(
                docComments = it.docComments,
                annotations = it.annotations,
                visibility = it.visibility,
                kind = IImpl(
                  decl = ImplDecl(
                    generics = decl.generics,
                    iface = decl.iface,
                    target = decl.target,
                    whereClause = decl.whereClause,
                    members = members,
                    span = decl.span
                  )
                ),
                span = it.span
              )
            )
            changed = true
          }
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if not changed {
    return file
  }
  file.copy(items = items)
}

/// `file` with the free function of each needed default of an interface it declares.
func crossAddDefaultFns(
  file: in SourceFile, ifaces: in Map[String, CrossIface], needs: in Map[String, List[String]]
): SourceFile {
  val pk = crossPkgName(file)
  val items: List[Item] = newList()
  for it in file.items {
    items.add(it)
  }
  val base = Expand.generatedSpanBase(file)
  val origins: Map[String, Span] = newMap()
  var changed = false
  for it in file.items {
    match it.kind {
      case IInterface(id) -> match mapGet(needs, pk + "." + id.name) {
        case Some(methods) -> {
          val batch: List[Item] = newList()
          for m in id.members {
            match m {
              case IMFunc(fn) -> if listContains(methods, fn.name) {
                batch.add(
                  Item(
                    docComments = newList(),
                    annotations = newList(),
                    visibility = Some(value = VisPub(span = fn.span)),
                    kind = IFunc(decl = crossDefaultFn(id, fn)),
                    span = fn.span
                  )
                )
              }
              case _ -> ()
            }
          }
          if batch.count > 0 {
            for g in Expand.respanGenerated(file, batch, base, it.span, origins) {
              items.add(g)
            }
            changed = true
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
  }
  if not changed {
    return file
  }
  file.copy(items = items)
}

/// Every file of a native build with the default methods its impls inherit from interfaces declared in other
/// packages of the build (#9451).  `files` holds one file per package; a file with nothing to inherit, and every
/// file of a build with no such impl, comes back unchanged.
pub func inheritCrossPackageDefaults(files: in List[SourceFile]): List[SourceFile] {
  val ifaces: Map[String, CrossIface] = newMap()
  for f in files {
    val pk = crossPkgName(f)
    for it in f.items {
      match it.kind {
        case IInterface(id) -> ifaces.add(pk + "." + id.name, CrossIface(pkg = pk, decl = id, span = it.span))
        case _ -> ()
      }
    }
  }
  if ifaces.count == 0 {
    return files
  }
  val needs: Map[String, List[String]] = newMap()
  val rewritten: List[SourceFile] = newList()
  for f in files {
    rewritten.add(crossRewriteConsumer(f, ifaces, needs))
  }
  if needs.count == 0 {
    return files
  }
  val result: List[SourceFile] = newList()
  for f in rewritten {
    result.add(crossAddDefaultFns(f, ifaces, needs))
  }
  result
}
