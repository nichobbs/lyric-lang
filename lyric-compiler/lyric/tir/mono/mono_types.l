//! mono_types.l - Lyric.Tir.Mono: the context of the TIR monomorphiser and its type
//! rules (docs/70 §7.2, §7.3, D500).
//!
//! The pass maps a bundle of TIR packages to a bundle with nothing generic left: every
//! generic function, method, record, protected type and union reached from a non-generic
//! body is replaced by an instance, an ordinary declaration under its own `SymbolId`
//! whose DefPath key is the generic's key with the type arguments in brackets
//! (`Std.Core::Option[Int]`, `Std.Core::Option[Int]::Some`, `App::map[Int,String](P1,P2)`).
//! Instances of every package live in one synthetic package, `Lyric.Mono.Instances`.
//! There is no inference: the arguments are on the call and construction nodes.
package Lyric.Tir.Mono

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build

/// The name of the synthetic package that holds every instance.
pub func instancesPackageName(): String {
  "Lyric.Mono.Instances"
}

/// A problem the pass met.  `code` is stable: `M0010` polymorphic recursion (an instance
/// would need an unbounded chain of ever larger type arguments), `I0003` is not used here
/// (the verifier reports it), `I0007` an instantiation the bundle cannot make.
pub record MonoDiag {
  code: String
  message: String
  sym: Option[SymbolId]
}

/// One instantiation: the generic's symbol, the concrete arguments, the instance's symbol.
pub record InstanceInfo {
  origin: SymbolId
  args: List[Ty]
  inst: SymbolId
}

/// The output bundle.  `pkgs` holds the input packages without their generic declarations and with
/// every generic use replaced by its instance, then the instances package last.  `instances` is the
/// table `(generic, arguments) -> instance`; `unresolved` counts, per kind, the generic uses left
/// as they were because their declaration is not in the bundle (a function whose body did not
/// build, a generic interface, a generic distinct type).
pub record MonoResult {
  pkgs: List[PackageBuild]
  instances: List[InstanceInfo]
  diags: List[MonoDiag]
  unresolved: Map[String, Int]
  /// The functions of `pkgs` (by symbol id) that call a generic function whose declaration is not in
  /// the bundle: its signature stays generic, so the verifier cannot accept the rewritten call.
  tainted: Map[Int, Bool]
}

record Pending {
  origin: TFnDecl
  args: List[Ty]
  inst: SymbolId
}

record MCtx {
  interner: DefPathInterner
  decls: Map[Int, TFnDecl]
  entries: Map[Int, TSymEntry]
  cases: Map[Int, List[SymbolId]]
  caseParent: Map[Int, SymbolId]
  insts: Map[String, SymbolId]
  instList: List[InstanceInfo]
  outSyms: List[TSymEntry]
  outFns: List[TFnDecl]
  outNames: Map[Int, String]
  outCases: Map[Int, List[SymbolId]]
  work: List[Pending]
  diags: List[MonoDiag]
  unresolved: Map[String, Int]
  nextNode: List[Int]
  /// The symbol of the function being rewritten, in slot 0.
  cur: List[Int]
  /// Output functions that call a generic function the bundle has no declaration of.
  tainted: Map[Int, Bool]
  /// Every `impl` block of the input (D860), generic or not.
  implDecls: List[TImplDecl] = newList()
  /// The impl blocks the pass produced: each instance of a generic impl, in the instances package.
  outImpls: List[TImplDecl] = newList()
  /// The generic impls already instantiated at an argument list, by `implKey`.
  implDone: Map[String, Bool] = newMap()
  /// How many entries of `instList` each generic impl (by symbol id) has been matched against: instances are only
  /// appended and a match depends on an instance's arguments alone, so a later pass resumes from here.
  implCursor: Map[Int, Int] = newMap()
  /// The methods of each interface by its symbol id.
  ifaceMethods: Map[Int, List[SymbolId]] = newMap()
  /// How many entries of `work` have been produced, in slot 0.
  workDone: List[Int] = newList()
}

/// What a body is read under: the declaration whose parameters are replaced (`owner`) by `args`.
/// `fresh` renumbers every node, as an instance body needs (node ids are unique within a package).
record Subst {
  owner: SymbolId
  args: List[Ty]
  fresh: Bool
}

/// The first node id of an instance body: above every id `renumberNodeIds` and the builder hand out.
func firstInstanceNodeId(): Int {
  500000000
}

func noSubst(): Subst {
  Subst(owner = SymbolId(id = 0), args = newList(), fresh = false)
}

func addDiag(c: in MCtx, code: in String, message: in String, sym: in Option[SymbolId]): Unit {
  c.diags.add(MonoDiag(code = code, message = message, sym = sym))
}

func noteUnresolved(c: in MCtx, kind: in String): Unit {
  val had = match mapGet(c.unresolved, kind) { case Some(n) -> n; case None -> 0 }
  if c.unresolved.containsKey(kind) {
    c.unresolved.remove(kind)
  }
  c.unresolved.add(kind, had + 1)
}

func freshNode(c: in MCtx): NodeId {
  val n = c.nextNode[0]
  c.nextNode[0] = n + 1
  NodeId(id = n)
}

func nid(c: in MCtx, s: in Subst, id: in NodeId): NodeId {
  if s.fresh {
    freshNode(c)
  } else {
    id
  }
}

func symKey(c: in MCtx, sym: in SymbolId): String {
  match defPathKeyOf(c.interner, sym) {
    case Some(k) -> k
    case None -> "#" + toString(sym.id)
  }
}

/// The last `::` segment of a DefPath key: a case's own name.
func lastSegment(key: in String): String {
  var start = 0
  var i = 0
  while i + 1 < key.length {
    if key.substring(i, 2) == "::" {
      start = i + 2
    }
    i = i + 1
  }
  key.substring(start, key.length - start)
}

func joinStrings(xs: in List[String], sep: in String): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + sep
    }
    s = s + xs[i]
    i = i + 1
  }
  s
}

/// The canonical, name-based spelling of a closed type: the same in every package and every
/// compilation, so an instance key is stable (docs/70 §4.2).
func tyKey(c: in MCtx, t: in Ty): String {
  match t {
    case TPrim(k) -> primKindName(k)
    case TTuple(xs) -> "(" + tyKeys(c, xs) + ")"
    case TNullable(i) -> tyKey(c, i) + "?"
    case TFunc(ps, r, asy) -> {
      val parts: List[String] = newList()
      for p in ps {
        parts.add(modeName(p.mode) + " " + tyKey(c, p.ty))
      };
      (if asy { "async " } else { "" }) + "func(" + joinStrings(parts, ",") + "):" + tyKey(c, r)
    }
    case TArray(len, e) -> match len {
      case ALKnown(n) -> "array[" + toString(n) + "," + tyKey(c, e) + "]"
      case ALParam(o, i) -> "array[param" + toString(i) + "," + tyKey(c, e) + "]"
      case ALUnsized -> "array[_," + tyKey(c, e) + "]"
    }
    case TSlice(e) -> "slice[" + tyKey(c, e) + "]"
    case TNamed(s, args) -> if args.count == 0 { symKey(c, s) } else { symKey(c, s) + "[" + tyKeys(c, args) + "]" }
    case TParam(o, i) -> "param(" + symKey(c, o) + "," + toString(i) + ")"
    case TRefined(u, lo, hi, inc) -> tyKey(c, u) + " range " +
      (match lo { case Some(v) -> toString(v); case None -> "MIN" }) +
      (if inc { "..=" } else { ".." }) +
      (match hi { case Some(v) -> toString(v); case None -> "MAX" })
    case TLen(n) -> toString(n)
    case TNever -> "Never"
    case TException -> "Exception"
    case TExtern(h) -> if h.args.count == 0 {
      "extern " + h.name
    } else {
      "extern " + h.name + "[" + tyKeys(c, h.args) + "]"
    }
  }
}

func tyKeys(c: in MCtx, xs: in List[Ty]): String {
  val parts: List[String] = newList()
  for x in xs {
    parts.add(tyKey(c, x))
  }
  joinStrings(parts, ",")
}

/// Whether `t` mentions a generic parameter: an instance is never made from such arguments.
func hasParam(t: in Ty): Bool {
  match t {
    case TPrim(_) -> false
    case TTuple(xs) -> anyParam(xs)
    case TNullable(i) -> hasParam(i)
    case TFunc(ps, r, _) -> {
      var found = hasParam(r)
      for p in ps {
        if hasParam(p.ty) {
          found = true
        }
      }
      found
    }
    case TArray(len, e) -> (match len { case ALParam(_, _) -> true; case _ -> false }) or hasParam(e)
    case TSlice(e) -> hasParam(e)
    case TNamed(_, args) -> anyParam(args)
    case TParam(_, _) -> true
    case TRefined(u, _, _, _) -> hasParam(u)
    case TLen(_) -> false
    case TNever -> false
    case TException -> false
    case TExtern(h) -> anyParam(h.args)
  }
}

func anyParam(xs: in List[Ty]): Bool {
  for x in xs {
    if hasParam(x) {
      return true
    }
  }
  false
}

func sLen(s: in Subst, len: in ArrayLen): ArrayLen {
  match len {
    case ALParam(o, i) -> if symbolIdEq(o, s.owner) and i >= 0 and i < s.args.count {
      match s.args[i] {
        case TLen(n) -> ALKnown(n = n)
        case _ -> len
      }
    } else {
      len
    }
    case _ -> len
  }
}

func sParams(s: in Subst, ps: in List[TParamTy]): List[TParamTy] {
  val res: List[TParamTy] = newList()
  for p in ps {
    res.add(TParamTy(mode = p.mode, ty = sTy(s, p.ty)))
  }
  res
}

func sTys(s: in Subst, xs: in List[Ty]): List[Ty] {
  val res: List[Ty] = newList()
  for x in xs {
    res.add(sTy(s, x))
  }
  res
}

/// `t` with the parameters of `s.owner` replaced by `s.args` and a value-generic array length by its
/// known length.  A generic application keeps its arguments: `iTy` turns it into an instance.
func sTy(s: in Subst, t: in Ty): Ty {
  match t {
    case TPrim(_) -> t
    case TTuple(xs) -> TTuple(elems = sTys(s, xs))
    case TNullable(i) -> TNullable(inner = sTy(s, i))
    case TFunc(ps, r, asy) -> TFunc(params = sParams(s, ps), ret = sTy(s, r), isAsync = asy)
    case TArray(len, e) -> TArray(len = sLen(s, len), element = sTy(s, e))
    case TSlice(e) -> TSlice(element = sTy(s, e))
    case TNamed(sym, args) -> TNamed(sym = sym, args = sTys(s, args))
    case TParam(o, i) -> if symbolIdEq(o, s.owner) and i >= 0 and i < s.args.count { s.args[i] } else { t }
    case TRefined(u, lo, hi, inc) -> TRefined(underlying = sTy(s, u), lo = lo, hi = hi, hiInclusive = inc)
    case TLen(_) -> t
    case TNever -> t
    case TException -> t
    case TExtern(h) -> TExtern(host = HostTypeRef(name = h.name, args = sTys(s, h.args)))
  }
}

func iTys(c: in MCtx, xs: in List[Ty]): List[Ty] {
  val res: List[Ty] = newList()
  for x in xs {
    res.add(iTy(c, x))
  }
  res
}

func iParams(c: in MCtx, ps: in List[TParamTy]): List[TParamTy] {
  val res: List[TParamTy] = newList()
  for p in ps {
    res.add(TParamTy(mode = p.mode, ty = iTy(c, p.ty)))
  }
  res
}

/// `t` with every generic application replaced by its instance.
func iTy(c: in MCtx, t: in Ty): Ty {
  match t {
    case TPrim(_) -> t
    case TTuple(xs) -> TTuple(elems = iTys(c, xs))
    case TNullable(i) -> TNullable(inner = iTy(c, i))
    case TFunc(ps, r, asy) -> TFunc(params = iParams(c, ps), ret = iTy(c, r), isAsync = asy)
    case TArray(len, e) -> TArray(len = len, element = iTy(c, e))
    case TSlice(e) -> TSlice(element = iTy(c, e))
    case TNamed(sym, args) -> if args.count == 0 {
      t
    } else {
      val a = iTys(c, args)
      match instType(c, sym, a) {
        case Some(inst) -> TNamed(sym = inst, args = newList())
        case None -> TNamed(sym = sym, args = a)
      }
    }
    case TParam(_, _) -> t
    case TRefined(u, lo, hi, inc) -> TRefined(underlying = iTy(c, u), lo = lo, hi = hi, hiInclusive = inc)
    case TLen(_) -> t
    case TNever -> t
    case TException -> t
    case TExtern(h) -> TExtern(host = HostTypeRef(name = h.name, args = iTys(c, h.args)))
  }
}

/// `t` as the pass leaves it: parameters substituted, generic applications instantiated.
func mTy(c: in MCtx, s: in Subst, t: in Ty): Ty {
  iTy(c, sTy(s, t))
}

func mTys(c: in MCtx, s: in Subst, xs: in List[Ty]): List[Ty] {
  val res: List[Ty] = newList()
  for x in xs {
    res.add(mTy(c, s, x))
  }
  res
}

/// The longest type key the pass will mint a symbol for: a longer one is polymorphic recursion,
/// whose instances would never end.
func maxKeyLength(): Int {
  1500
}

/// The instance of the generic type `sym` at the closed arguments `args`, made on first use, or
/// `None` when `sym` is not a generic declaration of the bundle (a built-in, an interface, a
/// distinct type, a type whose declaration the bundle lacks) or `args` is not closed.
func instType(c: in MCtx, sym: in SymbolId, args: in List[Ty]): Option[SymbolId] {
  if sym.id <= 0 or args.count == 0 or anyParam(args) {
    return None
  }
  val en = match mapGet(c.entries, sym.id) { case Some(e) -> e; case None -> return None }
  val isType = match en.kind { case TSkType -> true; case _ -> false }
  if not isType or en.typeParamCount != args.count {
    return None
  }
  val key = symKey(c, sym) + "[" + tyKeys(c, args) + "]"
  match mapGet(c.insts, key) {
    case Some(i) -> return Some(value = i)
    case None -> ()
  }
  if key.length > maxKeyLength() {
    addDiag(
      c,
      "M0010",
      "polymorphic recursion: the instances of " + symKey(c, sym) + " need ever larger type arguments",
      Some(value = sym)
    )
    return None
  }
  val inst = internDefPathKey(c.interner, key)
  c.insts.add(key, inst)
  c.outNames.add(inst.id, key)
  c.instList.add(InstanceInfo(origin = sym, args = args, inst = inst))
  val sub = Subst(owner = sym, args = args, fresh = false)
  match mapGet(c.cases, sym.id) {
    case Some(cs) -> {
      val instCases: List[SymbolId] = newList()
      for cs1 in cs {
        val caseKey = key + "::" + lastSegment(symKey(c, cs1))
        val ci = internDefPathKey(c.interner, caseKey)
        instCases.add(ci)
        c.outNames.add(ci.id, caseKey)
        c.caseParent.add(ci.id, inst)
        match mapGet(c.entries, cs1.id) {
          case Some(ce) -> c.outSyms.add(instCaseEntry(c, sub, ce, ci, inst))
          case None -> addDiag(
            c,
            "I0007",
            "the union " + symKey(c, sym) + " has a case with no entry: " + symKey(c, cs1),
            Some(value = cs1)
          )
        }
      }
      c.outCases.add(inst.id, instCases)
      c.outSyms.add(
        TSymEntry(
          sym = inst,
          kind = TSkType,
          typeParamCount = 0,
          sig = None,
          fields = newList(),
          ty = None,
          mutable = false
        )
      )
    }
    case None -> {
      val fs: List[TFieldSig] = newList()
      for f in en.fields {
        fs.add(TFieldSig(name = f.name, ty = mTy(c, sub, f.ty), mutable = f.mutable, dflt = f.dflt))
      }
      c.outSyms.add(
        TSymEntry(
          sym = inst,
          kind = TSkType,
          typeParamCount = 0,
          sig = None,
          fields = fs,
          ty = None,
          mutable = false,
          isRecord = en.isRecord
        )
      )
    }
  }
  Some(value = inst)
}

func instCaseEntry(c: in MCtx, sub: in Subst, ce: in TSymEntry, ci: in SymbolId, union: in SymbolId): TSymEntry {
  val fs: List[TFieldSig] = newList()
  for f in ce.fields {
    fs.add(TFieldSig(name = f.name, ty = mTy(c, sub, f.ty), mutable = f.mutable))
  }
  val sg: Option[TSig] = match ce.sig {
    case Some(sg0) -> Some(
      value = TSig(
        typeParamCount = 0,
        params = mParamTys(c, sub, sg0.params),
        ret = TNamed(sym = union, args = newList()),
        isAsync = sg0.isAsync
      )
    )
    case None -> None
  }
  TSymEntry(sym = ci, kind = ce.kind, typeParamCount = 0, sig = sg, fields = fs, ty = None, mutable = false)
}

func mParamTys(c: in MCtx, s: in Subst, ps: in List[TParamTy]): List[TParamTy] {
  val res: List[TParamTy] = newList()
  for p in ps {
    res.add(TParamTy(mode = p.mode, ty = mTy(c, s, p.ty)))
  }
  res
}

/// The instance of the case `caseSym` of the generic union `parent` at `args`, or `caseSym` itself
/// when the union is not instantiated.
func instCase(c: in MCtx, parent: in SymbolId, caseSym: in SymbolId, args: in List[Ty]): SymbolId {
  match instType(c, parent, args) {
    case Some(u) -> match mapGet(c.outCases, u.id) {
      case Some(cs) -> {
        match mapGet(c.cases, parent.id) {
          case Some(orig) -> {
            var i = 0
            while i < orig.count {
              if symbolIdEq(orig[i], caseSym) and i < cs.count {
                return cs[i]
              }
              i = i + 1
            }
          }
          case None -> ()
        }
        caseSym
      }
      case None -> caseSym
    }
    case None -> caseSym
  }
}

/// The key of the instance of the function whose generic key is `key`, at `args`: the arguments in
/// brackets before the parameter list, `App::map(P1,P2)` -> `App::map[Int,String](P1,P2)`.
func fnInstKey(key: in String, argKeys: in String): String {
  var i = 0
  while i < key.length {
    if key.substring(i, 1) == "(" {
      return key.substring(0, i) + "[" + argKeys + "]" + key.substring(i, key.length - i)
    }
    i = i + 1
  }
  key + "[" + argKeys + "]"
}

/// The instance of the generic function or member `d` at the closed `args`, made on first use; its
/// body is produced when the work list is drained.
func instFn(c: in MCtx, d: in TFnDecl, args: in List[Ty]): Option[SymbolId] {
  val key = fnInstKey(symKey(c, d.sym), tyKeys(c, args))
  match mapGet(c.insts, key) {
    case Some(i) -> return Some(value = i)
    case None -> ()
  }
  if key.length > maxKeyLength() {
    addDiag(
      c,
      "M0010",
      "polymorphic recursion: the instances of " + symKey(c, d.sym) + " need ever larger type arguments",
      Some(value = d.sym)
    )
    return None
  }
  val inst = internDefPathKey(c.interner, key)
  c.insts.add(key, inst)
  c.outNames.add(inst.id, key)
  c.instList.add(InstanceInfo(origin = d.sym, args = args, inst = inst))
  val pend = Pending(origin = d, args = args, inst = inst)
  c.work.add(pend)
  val sub = Subst(owner = d.sym, args = args, fresh = false)
  val ps: List[TParamTy] = newList()
  for p in d.params {
    ps.add(TParamTy(mode = p.mode, ty = mTy(c, sub, p.local.ty)))
  }
  val kind: TSymKind = match mapGet(c.entries, d.sym.id) { case Some(e) -> e.kind; case None -> TSkFunc }
  c.outSyms.add(
    TSymEntry(
      sym = inst,
      kind = kind,
      typeParamCount = 0,
      sig = Some(value = TSig(typeParamCount = 0, params = ps, ret = mTy(c, sub, d.ret), isAsync = d.isAsync)),
      fields = newList(),
      ty = None,
      mutable = false
    )
  )
  Some(value = inst)
}

/// The instance a call of `sym` at `args` names, or `None` when the call stays as written: no type
/// arguments, a function the bundle has no declaration of (its body did not build), or arguments
/// that are not closed.
func instCallee(c: in MCtx, sym: in SymbolId, args: in List[Ty]): Option[SymbolId] {
  if args.count == 0 {
    return None
  }
  match mapGet(c.decls, sym.id) {
    case Some(d) -> {
      if d.typeParams.count != args.count {
        addDiag(
          c,
          "I0007",
          "a call of " + symKey(c, sym) + " has " + toString(args.count) + " type arguments for " +
            toString(d.typeParams.count) +
            " parameters",
          Some(value = sym)
        )
        return None
      }
      if anyParam(args) {
        addDiag(c, "I0007", "a call of " + symKey(c, sym) + " has type arguments that are not closed", Some(value = sym))
        return None
      }
      instFn(c, d, args)
    }
    case None -> {
      noteUnresolved(c, "generic callee without a declaration")
      if not c.tainted.containsKey(c.cur[0]) {
        c.tainted.add(c.cur[0], true)
      }
      None
    }
  }
}

/// The part of a member's DefPath key from its name on: `get(Self)` of `App::Holder::get(Self)`.
func memberSuffix(key: in String): String {
  var open = -1
  var i = 0
  while i < key.length and open < 0 {
    if key.substring(i, 1) == "(" {
      open = i
    }
    i = i + 1
  }
  if open < 0 {
    return lastSegment(key)
  }
  lastSegment(key.substring(0, open)) + key.substring(open, key.length - open)
}

/// The methods the interface `iface` declares: the interface-method entries whose key is the interface's key
/// and one name.  In symbol order, which is declaration order.
func ifaceMethodsOf(c: in MCtx, iface: in SymbolId): List[SymbolId] {
  match mapGet(c.ifaceMethods, iface.id) {
    case Some(l) -> return l
    case None -> ()
  }
  val prefix = symKey(c, iface) + "::"
  val ids: List[Int] = newList()
  for id in mapKeys(c.entries) {
    match mapGet(c.entries, id) {
      case Some(en) -> match en.kind {
        case TSkInterfaceMethod -> {
          val k = symKey(c, en.sym)
          if k.startsWith(prefix) {
            val rest = k.substring(prefix.length, k.length - prefix.length)
            var open = rest.length
            var i = 0
            while i < rest.length and open == rest.length {
              if rest.substring(i, 1) == "(" {
                open = i
              }
              i = i + 1
            }
            if open > 0 and not rest.substring(0, open).contains("::") {
              ids.add(id)
            }
          }
        }
        case _ -> ()
      }
      case None -> ()
    }
  }
  var a = 1
  while a < ids.count {
    val x = ids[a]
    var b = a - 1
    while b >= 0 and ids[b] > x {
      ids[b + 1] = ids[b]
      b = b - 1
    }
    ids[b + 1] = x
    a = a + 1
  }
  val res: List[SymbolId] = newList()
  for id in ids {
    res.add(SymbolId(id = id))
  }
  c.ifaceMethods.add(iface.id, res)
  res
}

/// The method `method` of the generic interface `iface` at the closed `args`: an interface-method entry under the
/// instance of the interface, its signature over the arguments.  `None` when the interface cannot be instantiated.
func instIfaceMethod(c: in MCtx, iface: in SymbolId, args: in List[Ty], method: in SymbolId): Option[SymbolId] {
  val ifaceInst = match instType(c, iface, args) { case Some(i) -> i; case None -> return None }
  val en = match mapGet(c.entries, method.id) { case Some(e) -> e; case None -> return None }
  val sg = match en.sig { case Some(g) -> g; case None -> return None }
  val key = symKey(c, ifaceInst) + "::" + memberSuffix(symKey(c, method))
  match mapGet(c.insts, key) {
    case Some(i) -> return Some(value = i)
    case None -> ()
  }
  val inst = internDefPathKey(c.interner, key)
  c.insts.add(key, inst)
  c.outNames.add(inst.id, key)
  val sub = Subst(owner = iface, args = args, fresh = false)
  c.outSyms.add(
    TSymEntry(
      sym = inst,
      kind = TSkInterfaceMethod,
      typeParamCount = en.typeParamCount,
      sig = Some(
        value = TSig(
          typeParamCount = sg.typeParamCount,
          params = mParamTys(c, sub, sg.params),
          ret = mTy(c, sub, sg.ret),
          isAsync = sg.isAsync
        )
      ),
      fields = newList(),
      ty = None,
      mutable = false
    )
  )
  Some(value = inst)
}
