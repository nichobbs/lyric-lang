//! verifier/vcgen.l — verification-condition generator (WP/SP calculus).
//! M4.1 fragment: let/val/var, if/else, match (trivial patterns), calls.
//! Mirrors compiler/src/Lyric.Verifier/VCGen.fs (simplified: no cross-package
//! imports, no ProofMeta datatype encoding).
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// ─────────────────────────────────────────────────────────────────────────────
// §1. Verification environment.
// ─────────────────────────────────────────────────────────────────────────────
pub record VEnv {
  pub vars: Map[String, Term]
  pub varNames: List[String]
  pub sorts: Map[String, SortInfo]
  pub callees: Map[String, FunctionDecl]
  pub symbols: List[SymbolDecl]
  pub checkedArithmetic: Bool
  // Distinct-type alias map: `Cents` → `TRef(Long)` for `pub type Cents = Long`.
  // Threaded through every VEnv constructor so `sortOfTypeExprE` can recurse
  // through alias chains and produce the underlying primitive's sort (#3853).
  pub distincts: Map[String, TypeExpr]
  // The sort info of each record and protected-type field, keyed by its
  // selector (`<Type>__<field>`): its width for
  // `@proof_required(checked_arithmetic)` (#7871) and the range a field of a
  // range subtype carries into a proof (#7872).
  pub fieldInfos: Map[String, SortInfo]
  // Each non-generic record's field defaults in declaration order, so a
  // constructor call that leaves a defaulted field out is completed with
  // its default (#7873).
  pub recordDefaults: Map[String, List[Option[Expr]]]
  // One entry per verifier-synthesized name handed out so far — loop
  // havocs, call results, untranslated values — shared by every copy of
  // the environment, so no two of them ever share a name (#8101, #8102).
  pub fresh: List[Int]
  // `<Record>.<method>` for every method declared inside a record body: a
  // record's own method takes precedence over a dot-named function of the
  // same name, so a call to one never borrows the other's contract (#8101).
  pub recordMethods: Map[String, Bool]
  // The variables a postcondition being proved speaks of at the end of the
  // code walked — a loop invariant over the variables its body assigns, an
  // `ensures:` over the function's `out`/`inout` parameters — each with the
  // placeholder that stands for its final value in the postcondition.  Every
  // path's end substitutes the variable's value there for the placeholder
  // (`finishPost`, #8102).
  pub finals: List[FinalSlot]
  // The bindings a call may store into — `var` locals, `out`/`inout`
  // parameters, a protected type's `var` fields.  A call the verifier
  // cannot resolve may pass any of them to an `out`/`inout` parameter, so
  // each it is given holds a new value afterwards (#8102).
  pub mutables: List[String]
  // Inside a protected type's member, the names of its `func`/`entry`
  // members, which a bare call reaches before any top-level function.
  pub protectedMembers: List[String]
  // The functions whose contract is being translated at a call, innermost
  // last: a call reaching one of them again inside that contract is not
  // unfolded a second time (#8102).
  pub contractStack: List[String]
  // The functions on a cycle of the contract-call graph — whose
  // `requires:`/`ensures:` (or `@pure` body) reach themselves again.  Their
  // `ensures:` and body are never assumed at a call: a cycle can make them
  // contradictory (#8102).
  pub cyclic: List[String]
  // The types this file declares whose values are fully determined by what
  // `==` compares: enums, and records and unions every field of which is
  // immutable and of such a type.  A `@pure` call over arguments of these
  // types (and of the primitive value types) is congruent (#8109).
  pub valueTypes: Map[String, Bool]
  // The type parameters of the generic whose body or contract is being
  // translated.  `==` over one is an opaque equivalence there; a contract
  // instantiated at a call is checked again over the argument terms
  // (#8109).
  pub typeParams: List[String]
  // Copy helpers — use explicit names list to avoid iterating Map.keys on a
  // TypeBuilderInstantiation, which generates invalid IL.
}

pub record FinalSlot {
  pub varName: String
  pub placeholder: String
}

// Resolve a distinct-type chain to its underlying TypeExpr.  Stops on the first
// non-distinct type (primitive, record, generic application, etc.).  Bounded
// by a depth limit to defend against malformed cyclic alias declarations.
func resolveDistinct(distincts: in Map[String, TypeExpr], te: in TypeExpr): TypeExpr {
  var current = te
  var depth = 0
  while depth < 16 {
    match current.kind {
      case TRef(path) -> {
        if path.segments.count == 1 {
          val name = path.segments[0]
          match mapGet(distincts, name) {
            case Some(under) -> {
              current = under
              depth = depth + 1
            }
            case None -> return current
          }
        } else {
          return current
        }
      }
      case _ -> return current
    }
  }
  current
}

// Whether `te` names a file-level distinct type or alias: a single-segment
// name the file declares that no type parameter in scope shadows.
func namesFileDistinct(distincts: in Map[String, TypeExpr], typeParams: in List[String], te: in TypeExpr): Bool {
  match te.kind {
    case TRef(path) -> path.segments.count == 1 and not typeParams.contains(path.segments[0]) and
      distincts.containsKey(path.segments[0])
    case _ -> false
  }
}

// The file-level distinct type or alias `name` names here, unless a type
// parameter in scope shadows it (#8214).
func fileDistinct(env: in VEnv, name: in String): Option[TypeExpr] {
  if env.typeParams.contains(name) {
    None
  } else {
    mapGet(env.distincts, name)
  }
}

func isFileDistinct(env: in VEnv, name: in String): Bool {
  isSome(fileDistinct(env, name))
}

// Env-aware sort lookup that follows distinct-type chains (#3853).  Use this
// in vcgen wherever a TypeExpr is converted to a Sort; the env's
// `distincts` map carries the file-level `pub type X = Y` aliases registered
// in `goalsForFile`, a named range subtype (`type Port = UInt range 1 ..=
// 65535`) as its refined underlying type (#7872).  The type parameters of
// the generic being translated shadow every file-level type spelt the same.
pub func sortOfTypeExprE(env: in VEnv, te: in TypeExpr): SortInfo {
  sortOfTypeExprIn(env.distincts, env.typeParams, te)
}

// A type in a declaration outside any generic: a module-level `val`, a
// record or protected-type field.
pub func sortOfTypeExprWith(distincts: in Map[String, TypeExpr], te: in TypeExpr): SortInfo {
  sortOfTypeExprIn(distincts, noTypeParams(), te)
}

// A type written in `decl`'s signature, in the scope of `decl`'s own type
// parameters rather than the caller's (#8214).
func calleeSortInfo(env: in VEnv, decl: in FunctionDecl, te: in TypeExpr): SortInfo {
  sortOfTypeExprIn(env.distincts, typeParamNames(decl), te)
}

pub func sortOfTypeExprIn(distincts: in Map[String, TypeExpr], typeParams: in List[String], te: in TypeExpr): SortInfo {
  sortOfTypeExprDepth(distincts, typeParams, te, 0)
}

// Bounded like `resolveDistinct`, against a cyclic chain of range subtypes.
func sortOfTypeExprDepth(
  distincts: in Map[String, TypeExpr],
  typeParams: in List[String],
  te: in TypeExpr,
  depth: in Int,
): SortInfo {
  val si = sortOfTypeExprDepthRaw(distincts, typeParams, te, depth)
  if distincts.containsKey(shadowedMonadKey("Result")) or distincts.containsKey(shadowedMonadKey("Option")) {
    SortInfo(sort = unshadowMonadSort(distincts, si.sort), range = si.range, intBits = si.intBits)
  } else {
    si
  }
}

// `Result` and `Option` are the standard library's datatypes only where no
// other type of that name can be in scope (#8108).  `goalsForFile` marks a
// name the file declares, or may import from a package other than `Std.*`,
// with this key in the distinct-type map; its sorts are then an ordinary
// uninterpreted type, never `Lyric!Result`/`Lyric!Option`.
func shadowedMonadKey(name: in String): String {
  "!shadowed." + name
}

func unshadowMonadSort(distincts: in Map[String, TypeExpr], s: in Sort): Sort {
  match s {
    case SDatatype(name, args) -> {
      val newArgs: List[Sort] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(unshadowMonadSort(distincts, args[i]))
        i = i + 1
      }
      val shadowed = (isResultSort(s) or isOptionSort(s)) and distincts.containsKey(shadowedMonadKey(name))
      SDatatype(name = if shadowed { name + "!user" } else { name }, args = newArgs)
    }
    case SSlice(e) -> SSlice(element = unshadowMonadSort(distincts, e))
    case SArray(e) -> SArray(element = unshadowMonadSort(distincts, e))
    case _ -> s
  }
}

// Whether a type named `name` other than the standard library's may be in
// scope in `file`: declared there, imported by name or alias, or brought in
// by a whole-package import outside `Std.*`, whose contents are not known
// here.
func monadNameShadowed(file: in SourceFile, name: in String): Bool {
  if declaredTypeNames(file).contains(name) {
    return true
  }
  var j = 0
  while j < file.imports.count {
    val imp = file.imports[j]
    match imp.asAlias {
      case Some(a) -> {
        if a == name {
          return true
        }
      }
      case None -> ()
    }
    match imp.selector {
      case Some(sel) -> {
        val items: List[ImportItem] = match sel {
          case ISSingle(item) -> {
            val one: List[ImportItem] = newList()
            one.add(item)
            one
          }
          case ISGroup(group) -> group
        }
        var k = 0
        while k < items.count {
          val visible = match items[k].asAlias { case Some(a) -> a; case None -> items[k].name }
          if visible == name {
            return true
          }
          k = k + 1
        }
      }
      case None -> {
        val segs = imp.path.segments
        val isStd = segs.count > 0 and segs[0] == "Std"
        if not isStd and not isSome(imp.asAlias) {
          return true
        }
      }
    }
    j = j + 1
  }
  false
}

// A type parameter in scope (`typeParams`) shadows every file-level type
// spelt the same; a distinct type's or alias's own right-hand side is
// written at module level, outside every type parameter's scope (#8214).
func sortOfTypeExprDepthRaw(
  distincts: in Map[String, TypeExpr],
  typeParams: in List[String],
  te: in TypeExpr,
  depth: in Int,
): SortInfo {
  val viaFile = namesFileDistinct(distincts, typeParams, te)
  val resolved = if viaFile { resolveDistinct(distincts, te) } else { te }
  val typeScope = if viaFile { noTypeParams() } else { typeParams }
  match resolved.kind {
    // A range over a distinct alias (`Cents range 0 ..= 100` with `type
    // Cents = ULong`) takes the alias's underlying sort, so its bounds fold
    // signed or unsigned as that sort requires (#7848).
    case TRefined(underlying, range) -> {
      val baseTe = TypeExpr(kind = TRef(path = underlying), span = resolved.span)
      if namesFileDistinct(distincts, typeScope, baseTe) and depth < 16 {
        val base = sortOfTypeExprDepth(distincts, typeScope, baseTe, depth + 1)
        refinedSortInfo(base.sort, base.intBits, range)
      } else {
        sortOfTypeExprShadowed(resolved, typeScope)
      }
    }
    case _ -> sortOfTypeExprShadowed(resolved, typeScope)
  }
}

func copyVarMap(m: in Map[String, Term], names: in List[String]): Map[String, Term] {
  val result: Map[String, Term] = newMap()
  var i = 0
  while i < names.count {
    val k = names[i]
    match mapGet(m, k) {
      case Some(v) -> result.add(k, v)
      case None -> {
      }
    }
    i = i + 1
  }
  result
}

func copySortMap(m: in Map[String, SortInfo], names: in List[String]): Map[String, SortInfo] {
  val result: Map[String, SortInfo] = newMap()
  var i = 0
  while i < names.count {
    val k = names[i]
    match mapGet(m, k) {
      case Some(v) -> result.add(k, v)
      case None -> {
      }
    }
    i = i + 1
  }
  result
}

func copyNameList(names: in List[String]): List[String] {
  val result: List[String] = newList()
  var i = 0
  while i < names.count {
    result.add(names[i])
    i = i + 1
  }
  result
}

pub func envEmpty(callees: in Map[String, FunctionDecl], symbols: in List[SymbolDecl], checkedArithmetic: in Bool): VEnv {
  val vars: Map[String, Term] = newMap()
  val sorts: Map[String, SortInfo] = newMap()
  val varNames: List[String] = newList()
  val distincts: Map[String, TypeExpr] = newMap()
  val fieldInfos: Map[String, SortInfo] = newMap()
  val recordDefaults: Map[String, List[Option[Expr]]] = newMap()
  val fresh: List[Int] = newList()
  val recordMethods: Map[String, Bool] = newMap()
  val finals: List[FinalSlot] = newList()
  val mutables: List[String] = newList()
  val protectedMembers: List[String] = newList()
  val contractStack: List[String] = newList()
  val cyclic: List[String] = newList()
  val valueTypes: Map[String, Bool] = newMap()
  val typeParams: List[String] = newList()
  VEnv(
    vars = vars,
    varNames = varNames,
    sorts = sorts,
    callees = callees,
    symbols = symbols,
    checkedArithmetic = checkedArithmetic,
    distincts = distincts,
    fieldInfos = fieldInfos,
    recordDefaults = recordDefaults,
    fresh = fresh,
    recordMethods = recordMethods,
    finals = finals,
    mutables = mutables,
    protectedMembers = protectedMembers,
    contractStack = contractStack,
    cyclic = cyclic,
    valueTypes = valueTypes,
    typeParams = typeParams
  )
}

// Bind name as TVar with the given sort info; copies vars and sorts maps,
// excluding any existing binding for 'name' (shadowing support).
pub func envBind(name: in String, info: in SortInfo, env: in VEnv): VEnv {
  // Build prevNames = env.varNames minus 'name' (handles shadowing).
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name {
      prevNames.add(env.varNames[i])
    }
    i = i + 1
  }
  val vars2 = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, TVar(name = name, sort = info.sort))
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(
    vars = vars2,
    varNames = prevNames,
    sorts = sorts2,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

// Bind name with an explicit term (e.g. for let-binding substitution);
// excludes any existing binding for 'name' (shadowing support).
pub func envBindTerm(name: in String, term: in Term, info: in SortInfo, env: in VEnv): VEnv {
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name {
      prevNames.add(env.varNames[i])
    }
    i = i + 1
  }
  val vars2 = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, term)
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(
    vars = vars2,
    varNames = prevNames,
    sorts = sorts2,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

pub func envLookup(name: in String, env: in VEnv): Option[Term] {
  mapGet(env.vars, name)
}

pub func envLookupSort(name: in String, env: in VEnv): Option[SortInfo] {
  mapGet(env.sorts, name)
}

// A name for a value the verifier introduces — a loop's havocked variable,
// a call's result, a construct it does not model — that no other name in
// any goal has: `!` never appears in a Lyric identifier, and the counter is
// shared by every copy of the environment.  Two distinct values must never
// share a name, or the solver takes them for equal (#8101, #8102).
func freshName(env: in VEnv, base: in String): String {
  val n = env.fresh.count
  env.fresh.add(n)
  base + "!" + intToString(n)
}

// The names with an entry snapshot (`old.<name>`) that an enclosing
// quantifier binds here: the bound variable's solver name is
// `<name>!q!<n>` (`translateQuantifier`).
func quantifierShadowedSnapshots(env: in VEnv): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    val key = env.varNames[i]
    if key.startsWith("old.") {
      val name = key.substring(4, key.length - 4)
      match envLookup(name, env) {
        case Some(TVar(vn, _)) -> {
          if vn.startsWith(name + "!q!") and not names.contains(name) {
            names.add(name)
          }
        }
        case _ -> ()
      }
    }
    i = i + 1
  }
  names
}

func oldShadowSentinel(name: in String): String {
  "old!shadowed!" + name
}

// `env` with each name that has an entry snapshot `old.<name>` bound to
// that snapshot.
func envAtEntry(env: in VEnv): VEnv {
  var entryEnv = env
  var i = 0
  while i < env.varNames.count {
    val key = env.varNames[i]
    if key.startsWith("old.") {
      val name = key.substring(4, key.length - 4)
      match envLookup(key, env) {
        case Some(t) -> match envLookupSort(key, env) {
          case Some(info) -> {
            entryEnv = envBindTerm(name, t, info, entryEnv)
          }
          case None -> ()
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  entryEnv
}

// An unconstrained value of `srt` with a name of its own.
func freshVar(env: in VEnv, base: in String, srt: in Sort): Term {
  TVar(name = freshName(env, base), sort = srt)
}

// ─────────────────────────────────────────────────────────────────────────────
// §1a. Block scopes (#8109).
// ─────────────────────────────────────────────────────────────────────────────
// The walk flattens an `if` statement: each branch is walked followed by the
// rest of the enclosing block (`wpIfStmt`).  A binding a branch declares
// must not reach that rest, so each branch — like a function, lambda or loop
// body — is a scope.  The first time a scope declares a name, the binding it
// shadows (or that there was none) is saved under a hidden key, and the
// scope's end, a marker statement after the branch, restores it.  The
// hidden keys hold `!`, which no Lyric identifier does.  While a variable a
// postcondition speaks of (`env.finals`) is shadowed it cannot change, so
// its placeholder reads the saved binding meanwhile.
func scopeCurrentKey(): String {
  "!scope"
}

func scopeSavedKey(scopeId: in String, name: in String): String {
  "!saved!" + scopeId + "!" + name
}

func scopeSavedMutableKey(scopeId: in String, name: in String): String {
  "!savedmut!" + scopeId + "!" + name
}

func scopeParentKey(scopeId: in String): String {
  "!parent!" + scopeId
}

func scopeAbsentName(): String {
  "!absent"
}

// The scope declarations in `env` go to, or "" outside every scope.
func currentScopeId(env: in VEnv): String {
  match envLookup(scopeCurrentKey(), env) {
    case Some(t) -> match t { case TVar(id, _) -> id; case _ -> "" }
    case None -> ""
  }
}

// `env` with `name` unbound.
func envUnbind(name: in String, env: in VEnv): VEnv {
  if not env.vars.containsKey(name) {
    return env
  }
  val names: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name {
      names.add(env.varNames[i])
    }
    i = i + 1
  }
  VEnv(
    vars = copyVarMap(env.vars, names),
    varNames = names,
    sorts = copySortMap(env.sorts, names),
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

// `finals` with each placeholder that reads `from` reading `to` instead.
func retargetFinals(finals: in List[FinalSlot], from: in String, to: in String): List[FinalSlot] {
  val moved: List[FinalSlot] = newList()
  var i = 0
  while i < finals.count {
    val slot = finals[i]
    moved.add(if slot.varName == from { FinalSlot(varName = to, placeholder = slot.placeholder) } else { slot })
    i = i + 1
  }
  moved
}

// A new scope, `scopeId`, inside the current one.
func envEnterScope(env: in VEnv, scopeId: in String): VEnv {
  val marker = TVar(name = scopeId, sort = SBool)
  val parent = match envLookup(scopeCurrentKey(), env) {
    case Some(t) -> envBindTerm(scopeParentKey(scopeId), t, unitSortInfo(), env)
    case None -> env
  }
  envBindTerm(scopeCurrentKey(), marker, unitSortInfo(), parent)
}

// `env` with `name` declared anew as `term`: a `val`, `var` or `let`, or a
// name a destructuring pattern binds.  An assignment is `envBindTerm`.
func envDeclare(name: in String, term: in Term, info: in SortInfo, env: in VEnv): VEnv {
  val scopeId = currentScopeId(env)
  var declEnv = env
  if scopeId.length > 0 {
    val savedKey = scopeSavedKey(scopeId, name)
    if not env.vars.containsKey(savedKey) {
      match envLookup(name, env) {
        case Some(outer) -> {
          val outerInfo = match envLookupSort(name, env) { case Some(si) -> si; case None -> info }
          declEnv = envBindTerm(savedKey, outer, outerInfo, declEnv)
          if env.mutables.contains(name) {
            declEnv = envBindTerm(scopeSavedMutableKey(scopeId, name), trueT(), unitSortInfo(), declEnv)
          }
        }
        case None -> {
          declEnv = envBindTerm(savedKey, TVar(name = scopeAbsentName(), sort = SBool), unitSortInfo(), declEnv)
        }
      }
      declEnv = envWithFinals(declEnv, retargetFinals(declEnv.finals, name, savedKey))
    }
  }
  envBindTerm(name, term, info, declEnv)
}

// `env` at the end of scope `scopeId`: each name it declared is bound as it
// was before, or unbound again, and the enclosing scope is current.
func envExitScope(env: in VEnv, scopeId: in String): VEnv {
  val prefix = "!saved!" + scopeId + "!"
  var outEnv = env
  var i = 0
  while i < env.varNames.count {
    val key = env.varNames[i]
    if key.startsWith(prefix) {
      val name = key.substring(prefix.length, key.length - prefix.length)
      val mutKey = scopeSavedMutableKey(scopeId, name)
      val wasMutable = env.vars.containsKey(mutKey)
      match envLookup(key, env) {
        case Some(saved) -> {
          val absent = match saved { case TVar(n, _) -> n == scopeAbsentName(); case _ -> false }
          if absent {
            outEnv = envSetMutable(envUnbind(name, outEnv), name, false)
          } else {
            val savedInfo = match envLookupSort(key, env) { case Some(si) -> si; case None -> unitSortInfo() }
            outEnv = envSetMutable(envBindTerm(name, saved, savedInfo, outEnv), name, wasMutable)
          }
        }
        case None -> ()
      }
      outEnv = envUnbind(mutKey, envUnbind(key, outEnv))
      outEnv = envWithFinals(outEnv, retargetFinals(outEnv.finals, key, name))
    }
    i = i + 1
  }
  match envLookup(scopeParentKey(scopeId), env) {
    case Some(parent) -> envBindTerm(
      scopeCurrentKey(),
      parent,
      unitSortInfo(),
      envUnbind(scopeParentKey(scopeId), outEnv)
    )
    case None -> envUnbind(scopeCurrentKey(), outEnv)
  }
}

// The statement that ends scope `scopeId` where the walk reaches it.  Its
// path's first segment holds `!`, so no source statement is one.
func scopeEndStmt(scopeId: in String, sp: in Span): Statement {
  val segs: List[String] = newList()
  segs.add("!scope-end")
  segs.add(scopeId)
  Statement(
    kind = SExpr(expr = Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)),
    span = sp
  )
}

func scopeEndOf(st: in Statement): Option[String] {
  match st.kind {
    case SExpr(x) -> match x.kind {
      case EPath(path) -> {
        if path.segments.count == 2 and path.segments[0] == "!scope-end" {
          Some(value = path.segments[1])
        } else {
          None
        }
      }
      case _ -> None
    }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Translation result.
// ─────────────────────────────────────────────────────────────────────────────
pub record TranslateResult {
  pub term: Term
  pub sideConds: List[Term]
  pub assumed: List[Term]
}

// `r` with its side conditions and facts holding only where `g` does: the
// translation of an operand evaluated only when `g` holds.
func guardTR(g: in Term, r: in TranslateResult): TranslateResult {
  TranslateResult(term = r.term, sideConds = guardTerms(g, r.sideConds), assumed = guardTerms(g, r.assumed))
}

func guardTerms(g: in Term, xs: in List[Term]): List[Term] {
  val guarded: List[Term] = newList()
  var i = 0
  while i < xs.count {
    guarded.add(mkImplies(g, xs[i]))
    i = i + 1
  }
  guarded
}

// `sides`, each stated where `facts` hold: the side conditions of what is
// evaluated after the code that brought `facts`.  Each side condition in a
// `TranslateResult` already holds under the facts of everything evaluated
// before it in the same expression, so the flat list keeps evaluation order
// (`side_1 and (fact_1 implies side_2) and ...`).  A call's own facts never
// guard its own precondition (#8102): they are brought after it is checked.
// The facts are copied, since a conjunction shares the list it is given.
func afterFacts(facts: in List[Term], sides: in List[Term]): List[Term] {
  if facts.count == 0 {
    return sides
  }
  val held: List[Term] = newList()
  appendTermList(held, facts)
  guardTerms(mkAnd(held), sides)
}

func singleTR(t: in Term): TranslateResult {
  val sc: List[Term] = newList()
  val asList: List[Term] = newList()
  TranslateResult(term = t, sideConds = sc, assumed = asList)
}

func appendTermList(dst: in List[Term], src: in List[Term]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// Scan env.symbols for a single-ctor `DeclDatatype` whose name matches.
// Returns the constructor's fields (name → sort) so EMember can emit a
// strongly-typed selector and ECall can emit a strongly-typed ctor call
// when the receiver type is a known record (#3843).  A generic record's
// field sorts name its sort parameters (`recordSortParams`); a reader
// instantiates them (`instantiateRecordSort`).
func findRecordFields(env: in VEnv, name: in String): Option[List[DatatypeField]] {
  var i = 0
  while i < env.symbols.count {
    match env.symbols[i] {
      case DeclDatatype(rName, ctors, _) -> {
        if rName == name and ctors.count >= 1 {
          val fieldsOpt: Option[List[DatatypeField]] = Some(value = ctors[0].fields)
          return fieldsOpt
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  val none: Option[List[DatatypeField]] = None
  none
}

// The sort parameters of the record datatype `name` (#8340): empty for a
// record that is not generic, or that is not registered.
func recordSortParams(env: in VEnv, name: in String): List[String] {
  for sym in env.symbols {
    match sym {
      case DeclDatatype(rName, ctors, params) -> {
        if rName == name and ctors.count >= 1 {
          return params
        }
      }
      case _ -> ()
    }
  }
  val none: List[String] = newList()
  none
}

// The sort parameter a generic record's datatype declares for its type
// parameter `typeParam` (#8340).  `!` keeps it apart from every source sort,
// a type of the file spelt like the parameter among them, and the
// `Lyric!sortparam!` prefix from every name the verifier synthesizes
// (`Lyric!Unit`, the tuple sorts), whatever the record and parameter are
// called.
func recordSortParamName(recordName: in String, typeParam: in String): String {
  "Lyric!sortparam!" + recordName + "!" + typeParam
}

// `s` with each sort `SDatatype(params[i], [])` replaced by `args[i]`.
func substSortParams(s: in Sort, params: in List[String], args: in List[Sort]): Sort {
  match s {
    case SDatatype(name, sargs) -> {
      if sargs.count == 0 {
        var i = 0
        while i < params.count {
          if params[i] == name {
            return args[i]
          }
          i = i + 1
        }
        s
      } else {
        val newArgs: List[Sort] = newList()
        for a in sargs {
          newArgs.add(substSortParams(a, params, args))
        }
        SDatatype(name = name, args = newArgs)
      }
    }
    case SSlice(e) -> SSlice(element = substSortParams(e, params, args))
    case SArray(e) -> SArray(element = substSortParams(e, params, args))
    case _ -> s
  }
}

// The sort a field of sort `fieldSort` has on a value of the record sort
// `recvSort`: the field's sort with the record's sort parameters replaced
// by the value's type arguments (#8340).  `None` when the value's sort does
// not apply the record to one argument per parameter.
func instantiateRecordSort(env: in VEnv, recvSort: in Sort, fieldSort: in Sort): Option[Sort] {
  match recvSort {
    case SDatatype(rName, targs) -> {
      val params = recordSortParams(env, rName)
      if params.count != targs.count {
        return None
      }
      if params.count == 0 {
        return Some(value = fieldSort)
      }
      Some(value = substSortParams(fieldSort, params, targs))
    }
    case _ -> None
  }
}

// Bind the sort parameters `params` so that `pattern` (a field's declared
// sort) is `actual` (the sort of the value given for it), recording each
// binding in `bound` (one slot per parameter, `None` while unbound).
// False when the two cannot agree: a parameter bound to two sorts, or
// sorts of different shapes.
func matchSortParams(pattern: in Sort, actual: in Sort, params: in List[String], bound: in List[Option[Sort]]): Bool {
  match pattern {
    case SDatatype(name, pargs) -> {
      if pargs.count == 0 {
        var i = 0
        while i < params.count {
          if params[i] == name {
            match bound[i] {
              case Some(prev) -> {
                return smtRenderSort(prev) == smtRenderSort(actual)
              }
              case None -> {
                bound[i] = Some(value = actual)
                return true
              }
            }
          }
          i = i + 1
        }
      }
      match actual {
        case SDatatype(aname, aargs) -> {
          if aname != name or aargs.count != pargs.count {
            return false
          }
          var j = 0
          while j < pargs.count {
            if not matchSortParams(pargs[j], aargs[j], params, bound) {
              return false
            }
            j = j + 1
          }
          true
        }
        case _ -> false
      }
    }
    case SSlice(pe) -> match actual { case SSlice(ae) -> matchSortParams(pe, ae, params, bound); case _ -> false }
    case SArray(pe) -> match actual { case SArray(ae) -> matchSortParams(pe, ae, params, bound); case _ -> false }
    case _ -> smtRenderSort(pattern) == smtRenderSort(actual)
  }
}

// `matchSortParams` for the argument `t` given a field of sort `pattern`:
// a `Some(x)`/`Ok(x)`/`Err(e)` not yet given its type binds the parameters
// its payload's sort fixes, and `None` binds none.
func matchArgSortParams(pattern: in Sort, t: in Term, params: in List[String], bound: in List[Option[Sort]]): Bool {
  val ctor = pendingCtorName(t)
  if ctor.length == 0 {
    return matchSortParams(pattern, sortOf(t), params, bound)
  }
  // A field of a parameter's own sort: `Some(x)` gives it `Option` of
  // `x`'s sort; any other constructor leaves part of it open.
  match pendingCtorSort(t) {
    case Some(srt) -> match pattern {
      case SDatatype(pn, pargs) -> {
        if pargs.count == 0 and params.contains(pn) {
          return matchSortParams(pattern, srt, params, bound)
        }
      }
      case _ -> ()
    }
    case None -> ()
  }
  val wantResult = ctor == "Ok" or ctor == "Err"
  val fits = if wantResult { isResultSort(pattern) } else { isOptionSort(pattern) }
  if not fits {
    return false
  }
  val payload = pendingCtorArgs(t)
  if payload.count == 0 {
    return true
  }
  val slot = if ctor == "Err" { monadArgSort(pattern, 1) } else { monadArgSort(pattern, 0) }
  matchArgSortParams(slot, payload[0], params, bound)
}

// The sort a `Some(x)` not yet given its type has: `Option` of `x`'s sort,
// when that is known; `None`, `Ok` and `Err` leave part of theirs open.
func pendingCtorSort(t: in Term): Option[Sort] {
  if pendingCtorName(t) != "Some" {
    return None
  }
  val payload = pendingCtorArgs(t)
  if payload.count != 1 {
    return None
  }
  val inner = match pendingCtorSort(payload[0]) {
    case Some(srt) -> srt
    case None -> {
      if pendingCtorName(payload[0]).length > 0 {
        return None
      }
      sortOf(payload[0])
    }
  }
  val args: List[Sort] = newList()
  args.add(inner)
  Some(value = SDatatype(name = "Option", args = args))
}

// Return the sort of a named field on a value of the record sort
// `recvSort`, or None if the record (or that field) isn't registered.
// Drives EMember's selector emission.
func findRecordFieldSort(env: in VEnv, recvSort: in Sort, fieldName: in String): Option[Sort] {
  val recName = match recvSort { case SDatatype(n, _) -> n; case _ -> "" }
  if recName.length == 0 {
    return None
  }
  // Selectors are registered with a `<TypeName>__` prefix (see
  // `goalsForFile` IRecord / IProtected) so a field named `capacity` on a
  // Bucket doesn't collide with a free constant of the same name in z3's
  // global name space (#3855).  Match against the prefixed form.
  val prefixed = recName + "__" + fieldName
  match findRecordFields(env, recName) {
    case Some(fields) -> {
      var j = 0
      while j < fields.count {
        if fields[j].name == prefixed {
          return instantiateRecordSort(env, recvSort, fields[j].sort)
        }
        j = j + 1
      }
      val noSort: Option[Sort] = None
      noSort
    }
    case None -> {
      val noRec: Option[Sort] = None
      noRec
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Literal translation.
// ─────────────────────────────────────────────────────────────────────────────
func translateLit(lit: in Literal): Term {
  match lit {
    case LBool(v) -> TLit(value = VLBool(b = v), sort = SBool)
    case LInt(v, suffix, _) -> {
      // An unsigned-suffixed literal is a bitvector constant of its type's
      // width; a wide `u64` literal (2^63 and up) already holds its
      // two's-complement pattern (#7839), which is exactly its bitvector
      // (#7848).  A signed or unsuffixed literal is an integer; one with no
      // suffix takes an unsigned operand's sort later (`coerceToSort`).
      match unsignedSuffixWidth(suffix) {
        case Some(w) -> TLit(value = VLBitVec(bits = v, width = w), sort = SBitVec(width = w))
        case None -> TLit(value = VLInt(n = v), sort = SInt)
      }
    }
    case LFloat(v, _, _) -> TLit(value = VLFloat(f = v), sort = SFloat64)
    case LString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LTripleString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LRawString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LChar(cp) -> TLit(value = VLInt(n = cp.toLong()), sort = SInt)
    case LUnit -> TLit(value = VLUnit, sort = unitSort())
  }
}

// V0033: a construct the verifier cannot translate faithfully.  The proof
// fails closed on it rather than reasoning about a term that means
// something other than the source (#7848).
func untranslatableDiag(reason: in String, sp: in Span): Diagnostic {
  errorDiagnostic("V0033", "cannot translate this into the proof logic faithfully: " + reason, sp)
}

// A term standing for a construct already reported as V0033.  It keeps
// every goal it reaches failed — the driver never hands such a goal to the
// discharger or the solver — without a second report at the goal (#7874).
func poisonTerm(t: in Term): Term {
  TApp(name = untranslatableMarker(), args = termList1(t), retSort = sortOf(t))
}

// The value of a `match` with an arm the verifier does not model (V0027):
// every goal it reaches fails closed, reported at the goal (#8230).
func unmodelledPatternTerm(t: in Term): Term {
  TApp(name = unmodelledPatternMarker(), args = termList1(t), retSort = sortOf(t))
}

// A callee contract or `@pure` body is translated once more at every call;
// a construct there that cannot be translated is reported (once, after
// `dedupeDiagnostics`) even when the callee itself is not proved.
func keepUntranslatableDiags(src: in List[Diagnostic], dst: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    if src[i].code == "V0033" {
      dst.add(src[i])
    }
    i = i + 1
  }
}

// Convert a translated value to the sort it is bound, passed or returned
// at (a literal taking an unsigned declared type, a lossless widening).  On
// failure the term is kept and a V0033 error is recorded.
func coerceTermAt(t: in Term, target: in Sort, sp: in Span, diagsOut: in List[Diagnostic]): Term {
  match coerceToSort(t, target) {
    case Ok(c) -> c
    case Err(reason) -> {
      diagsOut.add(untranslatableDiag(reason, sp))
      poisonTerm(t)
    }
  }
}

// A call's argument terms in the callee's parameter (or record's field)
// order, and whether its arguments could be paired with them.
pub record PairedArgs {
  pub terms: List[Term]
  pub paired: Bool
}

// Pair a call's arguments with `names` the way the type checker does —
// named arguments by name, positional ones into the free slots left to
// right (`Lyric.Parser.pairCallArgs`) — so a callee contract is instantiated
// with the argument each parameter actually receives, whatever order named
// arguments are written in (#7873).  A parameter the call leaves out takes
// its declared default, translated in `defaultEnv` — a default sees no
// other parameter, and one naming a value the verifier does not model fails
// closed (#8102).  Each term takes its slot's sort.  Arguments that cannot
// be paired, or an omitted parameter without a default, are V0033 and give
// poisoned terms, so no goal built from the call is discharged.
func pairArgTerms(
  calleeName: in String,
  names: in List[String],
  sorts: in List[Sort],
  defaults: in List[Option[Expr]],
  defaultEnv: in VEnv,
  args: in List[CallArg],
  rawArgTerms: in List[Term],
  argSpans: in List[Span],
  callSpan: in Span,
  sideOut: in List[Term],
  assumedOut: in List[Term],
  diagsOut: in List[Diagnostic],
): PairedArgs {
  val terms: List[Term] = newList()
  match pairCallArgs(names, 0, args) {
    case Ok(slots) -> {
      var pi = 0
      while pi < names.count {
        val slot = slots[pi]
        val t = if slot >= 0 {
          coerceTermAt(rawArgTerms[slot], sorts[pi], argSpans[slot], diagsOut)
        } else {
          val dflt: Option[Expr] = if pi < defaults.count { defaults[pi] } else { None }
          match dflt {
            case Some(d) -> {
              val (dR, dDiags) = translateExpr(defaultEnv, d)
              appendTermList2(diagsOut, dDiags)
              var k = 0
              while k < dR.sideConds.count {
                sideOut.add(dR.sideConds[k])
                k = k + 1
              }
              k = 0
              while k < dR.assumed.count {
                assumedOut.add(dR.assumed[k])
                k = k + 1
              }
              val dTerm = dR.term
              // A default naming something the verifier does not model — a
              // module-level `val` — would stand for an unrelated symbol of
              // the same name at the call; fail closed (#8102).
              if freeVarsOfTerm(dTerm).count > 0 {
                diagsOut.add(
                  untranslatableDiag(
                    "the default of '" + names[pi] + "' in the call to '" + calleeName + "' names a value the verifier does not model",
                    d.span
                  )
                )
                poisonTerm(coerceTermAt(dTerm, sorts[pi], d.span, diagsOut))
              } else {
                coerceTermAt(dTerm, sorts[pi], d.span, diagsOut)
              }
            }
            case None -> {
              diagsOut.add(
                untranslatableDiag(
                  "the call to '" + calleeName + "' gives no argument for '" + names[pi] + "', which has no default",
                  callSpan
                )
              )
              poisonTerm(TVar(name = names[pi], sort = sorts[pi]))
            }
          }
        }
        terms.add(t)
        pi = pi + 1
      }
      PairedArgs(terms = terms, paired = true)
    }
    case Err(why) -> {
      diagsOut.add(
        untranslatableDiag(
          "the arguments of the call to '" + calleeName + "' do not match its parameters: " + why,
          callSpan
        )
      )
      var pi = 0
      while pi < names.count {
        terms.add(poisonTerm(TVar(name = names[pi], sort = sorts[pi])))
        pi = pi + 1
      }
      PairedArgs(terms = terms, paired = false)
    }
  }
}

// `env` without its bindings, for an expression evaluated outside the
// caller's scope (a record field's default).
func varlessEnv(env: in VEnv): VEnv {
  val vars: Map[String, Term] = newMap()
  val sorts: Map[String, SortInfo] = newMap()
  val varNames: List[String] = newList()
  VEnv(
    vars = vars,
    varNames = varNames,
    sorts = sorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}
