//! verifier/vcir.l — Lyric-VC IR (docs/15-phase-4-proof-plan.md §6).
//!
//! A typed first-order logic close to SMT-LIB v2.6.  Solver-agnostic:
//! the SMT-LIB emitter (smt.l) is one back-end.
//!
//! Mirrors compiler/src/Lyric.Verifier/Vcir.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// §1. Sorts.
// ─────────────────────────────────────────────────────────────────────────────
pub union Sort {
  case SBool
  case SInt
  case SBitVec(width: Int)
  case SFloat32
  case SFloat64
  case SString
  // Algebraic datatypes — records, unions, enums, opaque types.
  case SDatatype(name: String, args: List[Sort])
  // slice[T] — a finite array with a separate length.
  case SSlice(element: Sort)
  // Uninterpreted sort for opaque protected-type refs and unmodelled resources.
  case SUninterp(name: String)
}

pub func sortDisplay(s: in Sort): String {
  match s {
    case SBool -> "Bool"
    case SInt -> "Int"
    case SBitVec(w) -> "BitVec[" + intToString(w) + "]"
    case SFloat32 -> "Float32"
    case SFloat64 -> "Float64"
    case SString -> "String"
    case SDatatype(n, args) -> {
      if args.count == 0 {
        n
      } else {
        val parts: List[String] = newList()
        var i = 0
        while i < args.count {
          parts.add(sortDisplay(args[i]))
          i = i + 1
        }
        n + "[" + joinSortList(parts) + "]"
      }
    }
    case SSlice(e) -> "Slice[" + sortDisplay(e) + "]"
    case SUninterp(n) -> n
  }
}

func joinSortList(xs: in List[String]): String {
  var result = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      result = result + ", "
    }
    result = result + xs[i]
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Builtins.
// ─────────────────────────────────────────────────────────────────────────────
pub union Builtin {
  // Boolean
  case BOpAnd
  case BOpOr
  case BOpNot
  case BOpXor
  case BOpImplies
  case BOpIff
  // Polymorphic equality
  case BOpEq
  case BOpNeq
  // Integer / bitvector
  case BOpAdd
  case BOpSub
  case BOpMul
  case BOpDiv
  case BOpMod
  case BOpNeg
  case BOpLt
  case BOpLte
  case BOpGt
  case BOpGte
  // Real-number division (SMT `/`).  Used for Float32/Float64 operands.
  case BOpRealDiv
  // Slice helpers
  case BOpSliceLength
  case BOpSliceIndex
  // If-then-else
  case BOpIte
}

pub func builtinDisplay(b: in Builtin): String {
  match b {
    case BOpAnd -> "and"
    case BOpOr -> "or"
    case BOpNot -> "not"
    case BOpXor -> "xor"
    case BOpImplies -> "=>"
    case BOpIff -> "="
    case BOpEq -> "="
    case BOpNeq -> "distinct"
    case BOpAdd -> "+"
    case BOpSub -> "-"
    case BOpMul -> "*"
    case BOpDiv -> "div"
    case BOpMod -> "mod"
    case BOpNeg -> "-"
    case BOpLt -> "<"
    case BOpLte -> "<="
    case BOpGt -> ">"
    case BOpGte -> ">="
    case BOpRealDiv -> "/"
    case BOpSliceLength -> "slice.length"
    case BOpSliceIndex -> "slice.select"
    case BOpIte -> "ite"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Literals.
// ─────────────────────────────────────────────────────────────────────────────
pub union Lit {
  case VLBool(b: Bool)
  case VLInt(n: Long)
  case VLFloat(f: Double)
  case VLString(s: String)
  case VLUnit
  // ─────────────────────────────────────────────────────────────────────────────
  // §4. Terms.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub union Term {
  case TVar(name: String, sort: Sort)
  case TLit(value: Lit, sort: Sort)
  case TBuiltin(op: Builtin, args: List[Term])
  case TApp(name: String, args: List[Term], retSort: Sort)
  case TLet(bindings: List[TermBinding], body: Term)
  case TIte(cond: Term, thenT: Term, elseT: Term)
  case TForall(binders: List[SortBinder], triggers: List[List[Term]], body: Term)
  case TExists(binders: List[SortBinder], body: Term)
}

pub record TermBinding {
  pub name: String
  pub term: Term
}

pub record SortBinder {
  pub name: String
  pub sort: Sort
  // Smart constructors.
}

pub func mkAnd(xs: in List[Term]): Term {
  if xs.count == 0 {
    TLit(value = VLBool(b = true), sort = SBool)
  } else if xs.count == 1 {
    xs[0]
  } else {
    TBuiltin(op = BOpAnd, args = xs)
  }
}

pub func mkOr(xs: in List[Term]): Term {
  if xs.count == 0 {
    TLit(value = VLBool(b = false), sort = SBool)
  } else if xs.count == 1 {
    xs[0]
  } else {
    TBuiltin(op = BOpOr, args = xs)
  }
}

pub func mkImplies(p: in Term, q: in Term): Term {
  TBuiltin(op = BOpImplies, args = termList2(p, q))
}

pub func mkNot(p: in Term): Term {
  TBuiltin(op = BOpNot, args = termList1(p))
}

pub func trueT(): Term {
  TLit(value = VLBool(b = true), sort = SBool)
}

pub func falseT(): Term {
  TLit(value = VLBool(b = false), sort = SBool)
}

// Helper to make small term lists without the List[T] mutable syntax noise.
pub func termList1(a: in Term): List[Term] {
  val xs: List[Term] = newList()
  xs.add(a)
  xs
}

pub func termList2(a: in Term, b: in Term): List[Term] {
  val xs: List[Term] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

pub func termList3(a: in Term, b: in Term, c: in Term): List[Term] {
  val xs: List[Term] = newList()
  xs.add(a)
  xs.add(b)
  xs.add(c)
  xs
}

// True when the term has no TVar references.
pub func isClosed(t: in Term): Bool {
  match t {
    case TVar(_, _) -> false
    case TLit(_, _) -> true
    case TBuiltin(_, args) -> allClosed(args)
    case TApp(_, args, _) -> allClosed(args)
    case TLet(bs, b) -> bindingsClosed(bs) and isClosed(b)
    case TIte(c, a, b) -> isClosed(c) and isClosed(a) and isClosed(b)
    case TForall(_, _, body) -> isClosed(body)
    case TExists(_, body) -> isClosed(body)
  }
}

func allClosed(xs: in List[Term]): Bool {
  var i = 0
  while i < xs.count {
    if not isClosed(xs[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func bindingsClosed(bs: in List[TermBinding]): Bool {
  var i = 0
  while i < bs.count {
    if not isClosed(bs[i].term) {
      return false
    }
    i = i + 1
  }
  true
}

// Sort of a term (best-effort).
pub func sortOf(t: in Term): Sort {
  match t {
    case TVar(_, s) -> s
    case TLit(_, s) -> s
    case TBuiltin(b, args) -> builtinResultSort(b, args)
    case TApp(_, _, s) -> s
    case TLet(_, body) -> sortOf(body)
    case TIte(_, a, _) -> sortOf(a)
    case TForall(_, _, _) -> SBool
    case TExists(_, _) -> SBool
  }
}

func builtinResultSort(b: in Builtin, args: in List[Term]): Sort {
  match b {
    case BOpAnd | BOpOr | BOpNot | BOpXor | BOpImplies | BOpIff | BOpEq | BOpNeq | BOpLt | BOpLte | BOpGt | BOpGte -> SBool
    case BOpAdd | BOpSub | BOpMul | BOpDiv | BOpMod | BOpNeg | BOpRealDiv -> {
      if args.count > 0 {
        sortOf(args[0])
      } else {
        SInt
      }
    }
    case BOpSliceLength -> SInt
    case BOpSliceIndex -> {
      if args.count > 0 {
        match sortOf(args[0]) {
          case SSlice(e) -> e
          case _ -> SInt
        }
      } else {
        SInt
      }
    }
    case BOpIte -> {
      if args.count >= 2 {
        sortOf(args[1])
      } else {
        SBool
      }
    }
  }
}

// Structural equality on terms — used by the trivial discharger.
pub func termEq(a: in Term, b: in Term): Bool {
  match a {
    case TVar(n1, s1) -> {
      match b {
        case TVar(n2, s2) -> n1 == n2 and sortEq(s1, s2)
        case _ -> false
      }
    }
    case TLit(l1, _) -> {
      match b {
        case TLit(l2, _) -> litEq(l1, l2)
        case _ -> false
      }
    }
    case TBuiltin(o1, xs) -> {
      match b {
        case TBuiltin(o2, ys) -> builtinEq(o1, o2) and termListEq(xs, ys)
        case _ -> false
      }
    }
    case TApp(n1, xs, _) -> {
      match b {
        case TApp(n2, ys, _) -> n1 == n2 and termListEq(xs, ys)
        case _ -> false
      }
    }
    case TIte(c1, a1, b1) -> {
      match b {
        case TIte(c2, a2, b2) -> termEq(c1, c2) and termEq(a1, a2) and termEq(b1, b2)
        case _ -> false
      }
    }
    case _ -> false
  }
}

func sortEq(a: in Sort, b: in Sort): Bool {
  match a {
    case SBool -> {
      match b {
        case SBool -> true
        case _ -> false
      }
    }
    case SInt -> {
      match b {
        case SInt -> true
        case _ -> false
      }
    }
    case SFloat32 -> {
      match b {
        case SFloat32 -> true
        case _ -> false
      }
    }
    case SFloat64 -> {
      match b {
        case SFloat64 -> true
        case _ -> false
      }
    }
    case SString -> {
      match b {
        case SString -> true
        case _ -> false
      }
    }
    case SBitVec(w1) -> {
      match b {
        case SBitVec(w2) -> w1 == w2
        case _ -> false
      }
    }
    case SDatatype(n1, _) -> {
      match b {
        case SDatatype(n2, _) -> n1 == n2
        case _ -> false
      }
    }
    case SSlice(e1) -> {
      match b {
        case SSlice(e2) -> sortEq(e1, e2)
        case _ -> false
      }
    }
    case SUninterp(n1) -> {
      match b {
        case SUninterp(n2) -> n1 == n2
        case _ -> false
      }
    }
  }
}

func litEq(a: in Lit, b: in Lit): Bool {
  match a {
    case VLBool(x) -> {
      match b {
        case VLBool(y) -> x == y
        case _ -> false
      }
    }
    case VLInt(x) -> {
      match b {
        case VLInt(y) -> x == y
        case _ -> false
      }
    }
    case VLFloat(x) -> {
      match b {
        case VLFloat(y) -> x == y
        case _ -> false
      }
    }
    case VLString(x) -> {
      match b {
        case VLString(y) -> x == y
        case _ -> false
      }
    }
    case VLUnit -> {
      match b {
        case VLUnit -> true
        case _ -> false
      }
    }
  }
}

func builtinEq(a: in Builtin, b: in Builtin): Bool {
  match a {
    case BOpAnd -> {
      match b {
        case BOpAnd -> true
        case _ -> false
      }
    }
    case BOpOr -> {
      match b {
        case BOpOr -> true
        case _ -> false
      }
    }
    case BOpNot -> {
      match b {
        case BOpNot -> true
        case _ -> false
      }
    }
    case BOpXor -> {
      match b {
        case BOpXor -> true
        case _ -> false
      }
    }
    case BOpImplies -> {
      match b {
        case BOpImplies -> true
        case _ -> false
      }
    }
    case BOpIff -> {
      match b {
        case BOpIff -> true
        case _ -> false
      }
    }
    case BOpEq -> {
      match b {
        case BOpEq -> true
        case _ -> false
      }
    }
    case BOpNeq -> {
      match b {
        case BOpNeq -> true
        case _ -> false
      }
    }
    case BOpAdd -> {
      match b {
        case BOpAdd -> true
        case _ -> false
      }
    }
    case BOpSub -> {
      match b {
        case BOpSub -> true
        case _ -> false
      }
    }
    case BOpMul -> {
      match b {
        case BOpMul -> true
        case _ -> false
      }
    }
    case BOpDiv -> {
      match b {
        case BOpDiv -> true
        case _ -> false
      }
    }
    case BOpMod -> {
      match b {
        case BOpMod -> true
        case _ -> false
      }
    }
    case BOpNeg -> {
      match b {
        case BOpNeg -> true
        case _ -> false
      }
    }
    case BOpLt -> {
      match b {
        case BOpLt -> true
        case _ -> false
      }
    }
    case BOpLte -> {
      match b {
        case BOpLte -> true
        case _ -> false
      }
    }
    case BOpGt -> {
      match b {
        case BOpGt -> true
        case _ -> false
      }
    }
    case BOpGte -> {
      match b {
        case BOpGte -> true
        case _ -> false
      }
    }
    case BOpRealDiv -> {
      match b {
        case BOpRealDiv -> true
        case _ -> false
      }
    }
    case BOpSliceLength -> {
      match b {
        case BOpSliceLength -> true
        case _ -> false
      }
    }
    case BOpSliceIndex -> {
      match b {
        case BOpSliceIndex -> true
        case _ -> false
      }
    }
    case BOpIte -> {
      match b {
        case BOpIte -> true
        case _ -> false
      }
    }
  }
}

func termListEq(xs: in List[Term], ys: in List[Term]): Bool {
  if xs.count != ys.count {
    return false
  }
  var i = 0
  while i < xs.count {
    if not termEq(xs[i], ys[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// Free variable collection used to detect capture during substitution.
// Returns names in insertion order; duplicates are filtered before any
// membership query via `nameMember`.
pub func freeVarsOfTerm(t: in Term): List[String] {
  val acc: List[String] = newList()
  accumulateFreeVars(t, acc)
  acc
}

func accumulateFreeVars(t: in Term, acc: inout List[String]): Unit {
  match t {
    case TVar(name, _) -> {
      if not nameMember(acc, name) {
        acc.add(name)
      }
    }
    case TLit(_, _) -> {
    }
    case TBuiltin(_, args) -> {
      var i = 0
      while i < args.count {
        accumulateFreeVars(args[i], acc)
        i = i + 1
      }
    }
    case TApp(_, args, _) -> {
      var i = 0
      while i < args.count {
        accumulateFreeVars(args[i], acc)
        i = i + 1
      }
    }
    case TLet(bs, body) -> {
      // Init RHSes are in the outer scope; body shadows bound names.
      var i = 0
      while i < bs.count {
        accumulateFreeVars(bs[i].term, acc)
        i = i + 1
      }
      val inner: List[String] = newList()
      accumulateFreeVars(body, inner)
      var j = 0
      while j < inner.count {
        val n = inner[j]
        var shadowed = false
        var k = 0
        while k < bs.count {
          if bs[k].name == n {
            shadowed = true
          }
          k = k + 1
        }
        if not shadowed and not nameMember(acc, n) {
          acc.add(n)
        }
        j = j + 1
      }
    }
    case TIte(c, a, b) -> {
      accumulateFreeVars(c, acc)
      accumulateFreeVars(a, acc)
      accumulateFreeVars(b, acc)
    }
    case TForall(binders, triggers, body) -> {
      val inner: List[String] = newList()
      var i = 0
      while i < triggers.count {
        var j = 0
        while j < triggers[i].count {
          accumulateFreeVars(triggers[i][j], inner)
          j = j + 1
        }
        i = i + 1
      }
      accumulateFreeVars(body, inner)
      addUnshadowed(inner, binders, acc)
    }
    case TExists(binders, body) -> {
      val inner: List[String] = newList()
      accumulateFreeVars(body, inner)
      addUnshadowed(inner, binders, acc)
    }
  }
}

func addUnshadowed(inner: in List[String], binders: in List[SortBinder], acc: inout List[String]): Unit {
  var j = 0
  while j < inner.count {
    val n = inner[j]
    var shadowed = false
    var k = 0
    while k < binders.count {
      if binders[k].name == n {
        shadowed = true
      }
      k = k + 1
    }
    if not shadowed and not nameMember(acc, n) {
      acc.add(n)
    }
    j = j + 1
  }
}

func nameMember(xs: in List[String], n: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == n {
      return true
    }
    i = i + 1
  }
  false
}

// Generate a name not already in `taken` by appending `$<n>` for
// increasing n.  No module-level mutable state required.
func freshNameAvoiding(base_: in String, taken: in List[String]): String {
  var n = 1
  var candidate = base_ + "$" + intToString(n)
  while nameMember(taken, candidate) {
    n = n + 1
    candidate = base_ + "$" + intToString(n)
  }
  candidate
}

// Aggregate free vars across every term in env's codomain.
func envCodomainFreeVars(env: in Map[String, Term], envNames: in List[String]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < envNames.count {
    match mapGet(env, envNames[i]) {
      case Some(v) -> accumulateFreeVars(v, acc)
      case None -> {
      }
    }
    i = i + 1
  }
  acc
}

// Result type for alphaRenameBinders.
record AlphaRenameResult {
  newBinders: List[SortBinder]
  rename: Map[String, Term]
  renameNames: List[String]
  // Compute the capture-avoiding binder renaming needed when substituting `env2`
  // (already filtered to exclude binder-shadowed names) into a quantifier body.
  // Any binder name that appears free in the surviving env codomain is freshened
  // so the substitution cannot capture it.
}

func alphaRenameBinders(
  binders: in List[SortBinder],
  captured: in List[String],
  env2: in Map[String, Term],
  envNames2: in List[String],
): AlphaRenameResult {
  val taken: List[String] = newList()
  var ki = 0
  while ki < captured.count {
    taken.add(captured[ki])
    ki = ki + 1
  }
  var bi = 0
  while bi < binders.count {
    if not nameMember(taken, binders[bi].name) {
      taken.add(binders[bi].name)
    }
    bi = bi + 1
  }
  val newBinders: List[SortBinder] = newList()
  var rename: Map[String, Term] = env2
  val renameNames: List[String] = newList()
  var k = 0
  while k < envNames2.count {
    renameNames.add(envNames2[k])
    k = k + 1
  }
  var i = 0
  while i < binders.count {
    val b = binders[i]
    if nameMember(captured, b.name) {
      val fresh = freshNameAvoiding(b.name, taken)
      taken.add(fresh)
      rename.add(b.name, TVar(name = fresh, sort = b.sort))
      if not nameMember(renameNames, b.name) {
        renameNames.add(b.name)
      }
      newBinders.add(SortBinder(name = fresh, sort = b.sort))
    } else {
      newBinders.add(b)
    }
    i = i + 1
  }
  AlphaRenameResult(newBinders = newBinders, rename = rename, renameNames = renameNames)
}

// Capture-avoiding substitution.  envNames must contain exactly the keys
// of env (maintained as a parallel list to avoid iterating Map.keys on a
// TypeBuilderInstantiation, which generates invalid IL).
//
// When a binder name appears free in any term in the surviving env's
// codomain, the binder is alpha-renamed to a fresh `<name>$<N>` and the
// rename is threaded through every term that the binder scopes over —
// closing the soundness hole described in lyric-lang #312 (a
// substitution `{x -> y}` into `forall y. x > y` previously collapsed
// to `forall y. y > y`).
pub func substTerm(env: in Map[String, Term], envNames: in List[String], t: in Term): Term {
  match t {
    case TVar(name, _) -> {
      match mapGet(env, name) {
        case Some(replacement) -> replacement
        case None -> t
      }
    }
    case TLit(_, _) -> t
    case TBuiltin(op, args) -> {
      val newArgs: List[Term] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(substTerm(env, envNames, args[i]))
        i = i + 1
      }
      TBuiltin(op = op, args = newArgs)
    }
    case TApp(name, args, s) -> {
      val newArgs: List[Term] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(substTerm(env, envNames, args[i]))
        i = i + 1
      }
      TApp(name = name, args = newArgs, retSort = s)
    }
    case TLet(bs, body) -> {
      // Init RHSes are evaluated in the outer scope.
      val bs0: List[TermBinding] = newList()
      var i = 0
      while i < bs.count {
        bs0.add(TermBinding(name = bs[i].name, term = substTerm(env, envNames, bs[i].term)))
        i = i + 1
      }
      // Body env removes the bound names from the outer env.
      val envNames2: List[String] = filterNames(envNames, bs)
      val env2: Map[String, Term] = copyMap(env, envNames2)
      // Alpha-rename any binder that would capture a free var from env2.
      // The freshened name must avoid *both* the env's codomain AND any
      // sibling binder names — otherwise a freshly-generated `x$N` could
      // collide with an adjacent unrenamed binder (see #448 #456).
      val captured = envCodomainFreeVars(env2, envNames2)
      val taken: List[String] = newList()
      var ki = 0
      while ki < captured.count {
        taken.add(captured[ki])
        ki = ki + 1
      }
      var ji = 0
      while ji < bs.count {
        if not nameMember(taken, bs[ji].name) {
          taken.add(bs[ji].name)
        }
        ji = ji + 1
      }
      val newBs: List[TermBinding] = newList()
      var rename: Map[String, Term] = env2
      val renameNames: List[String] = newList()
      var k = 0
      while k < envNames2.count {
        renameNames.add(envNames2[k])
        k = k + 1
      }
      var j = 0
      while j < bs0.count {
        val orig = bs0[j]
        if nameMember(captured, orig.name) {
          val fresh = freshNameAvoiding(orig.name, taken)
          taken.add(fresh)
          rename.add(orig.name, TVar(name = fresh, sort = sortOf(orig.term)))
          if not nameMember(renameNames, orig.name) {
            renameNames.add(orig.name)
          }
          newBs.add(TermBinding(name = fresh, term = orig.term))
        } else {
          newBs.add(orig)
        }
        j = j + 1
      }
      TLet(bindings = newBs, body = substTerm(rename, renameNames, body))
    }
    case TIte(c, a, b) -> TIte(cond = substTerm(env, envNames, c), thenT = substTerm(env, envNames, a), elseT = substTerm(env, envNames, b))
    case TForall(binders, triggers, body) -> {
      val envNames2: List[String] = filterNamesByBinders(envNames, binders)
      val env2: Map[String, Term] = copyMap(env, envNames2)
      val captured = envCodomainFreeVars(env2, envNames2)
      val ar = alphaRenameBinders(binders, captured, env2, envNames2)
      val newTriggers: List[List[Term]] = newList()
      var ti = 0
      while ti < triggers.count {
        val row: List[Term] = newList()
        var tj = 0
        while tj < triggers[ti].count {
          row.add(substTerm(ar.rename, ar.renameNames, triggers[ti][tj]))
          tj = tj + 1
        }
        newTriggers.add(row)
        ti = ti + 1
      }
      TForall(binders = ar.newBinders, triggers = newTriggers, body = substTerm(ar.rename, ar.renameNames, body))
    }
    case TExists(binders, body) -> {
      val envNames2: List[String] = filterNamesByBinders(envNames, binders)
      val env2: Map[String, Term] = copyMap(env, envNames2)
      val captured = envCodomainFreeVars(env2, envNames2)
      val ar = alphaRenameBinders(binders, captured, env2, envNames2)
      TExists(binders = ar.newBinders, body = substTerm(ar.rename, ar.renameNames, body))
    }
  }
}

// Filter envNames to exclude names bound by bs (TermBinding list).
func filterNames(envNames: in List[String], bs: in List[TermBinding]): List[String] {
  val result: List[String] = newList()
  var i = 0
  while i < envNames.count {
    var shadowed = false
    var j = 0
    while j < bs.count {
      if envNames[i] == bs[j].name {
        shadowed = true
      }
      j = j + 1
    }
    if not shadowed {
      result.add(envNames[i])
    }
    i = i + 1
  }
  result
}

// Filter envNames to exclude names bound by quantifier binders.
func filterNamesByBinders(envNames: in List[String], binders: in List[SortBinder]): List[String] {
  val result: List[String] = newList()
  var i = 0
  while i < envNames.count {
    var shadowed = false
    var j = 0
    while j < binders.count {
      if envNames[i] == binders[j].name {
        shadowed = true
      }
      j = j + 1
    }
    if not shadowed {
      result.add(envNames[i])
    }
    i = i + 1
  }
  result
}

// Shallow copy of a Map[String, Term] using an explicit names list.
func copyMap(m: in Map[String, Term], names: in List[String]): Map[String, Term] {
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

// ─────────────────────────────────────────────────────────────────────────────
// §5. Goal kinds, symbol declarations, and goals.
// ─────────────────────────────────────────────────────────────────────────────
pub union GoalKind {
  case GKPrecondition(fnName: String)
  case GKPostcondition(fnName: String)
  case GKReturnInvariant(typeName: String)
  case GKConstructionInv(typeName: String)
  case GKLoopEstablish
  case GKLoopPreserve
  case GKLoopConclude
  case GKAssertion
  case GKRangeBound
}

pub func goalKindDisplay(k: in GoalKind): String {
  match k {
    case GKPrecondition(fn) -> "precondition of " + fn
    case GKPostcondition(fn) -> "postcondition of " + fn
    case GKReturnInvariant(tn) -> "return-invariant of " + tn
    case GKConstructionInv(tn) -> "construction invariant of " + tn
    case GKLoopEstablish -> "loop invariant (establish)"
    case GKLoopPreserve -> "loop invariant (preserve)"
    case GKLoopConclude -> "loop invariant (conclude)"
    case GKAssertion -> "user assertion"
    case GKRangeBound -> "range-subtype bound"
  }
}

pub union SymbolDecl {
  case DeclUserFun(name: String, paramSorts: List[Sort], resultSort: Sort)
  case DeclDatatype(name: String, constructors: List[DatatypeCtor])
}

pub record DatatypeCtor {
  pub name: String
  pub fields: List[DatatypeField]
}

pub record DatatypeField {
  pub name: String
  pub sort: Sort
}

pub record Goal {
  pub hypotheses: List[Term]
  pub conclusion: Term
  pub symbols: List[SymbolDecl]
  pub origin: Span
  pub kind: GoalKind
  pub label: String
}

pub func goalAsImplication(g: in Goal): Term {
  mkImplies(mkAnd(g.hypotheses), g.conclusion)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Pretty-printer (for --explain output).
// ─────────────────────────────────────────────────────────────────────────────
pub func prettyTerm(t: in Term): String {
  renderTerm(0, t)
}

func renderTerm(prec: in Int, t: in Term): String {
  match t {
    case TVar(name, _) -> name
    case TLit(VLBool(true), _) -> "true"
    case TLit(VLBool(false), _) -> "false"
    case TLit(VLInt(n), _) -> {
      if n < 0i64 {
        "(-" + longToString(-n) + ")"
      } else {
        longToString(n)
      }
    }
    case TLit(VLFloat(f), _) -> doubleToString(f)
    case TLit(VLString(s), _) -> "\"" + s + "\""
    case TLit(VLUnit, _) -> "()"
    case TBuiltin(BOpNot, args) -> {
      if args.count == 1 {
        "!" + renderTerm(10, args[0])
      } else {
        "not(...)"
      }
    }
    case TBuiltin(BOpNeg, args) -> {
      if args.count == 1 {
        "-" + renderTerm(10, args[0])
      } else {
        "neg(...)"
      }
    }
    case TBuiltin(BOpAnd, args) -> {
      val inner = joinTerms(args, " && ", 3)
      if prec > 3 {
        "(" + inner + ")"
      } else {
        inner
      }
    }
    case TBuiltin(BOpOr, args) -> {
      val inner = joinTerms(args, " || ", 2)
      if prec > 2 {
        "(" + inner + ")"
      } else {
        inner
      }
    }
    case TBuiltin(BOpImplies, args) -> {
      if args.count == 2 {
        val inner = renderTerm(4, args[0]) + " => " + renderTerm(1, args[1])
        if prec > 1 {
          "(" + inner + ")"
        } else {
          inner
        }
      } else {
        "=>(...)"
      }
    }
    case TBuiltin(BOpEq, args) -> {
      if args.count == 2 {
        renderTerm(5, args[0]) + " == " + renderTerm(5, args[1])
      } else {
        "==(...)"
      }
    }
    case TBuiltin(BOpNeq, args) -> {
      if args.count == 2 {
        renderTerm(5, args[0]) + " != " + renderTerm(5, args[1])
      } else {
        "!=(...)"
      }
    }
    case TBuiltin(BOpLt, args) -> renderBinOp(prec, args, " < ", 5)
    case TBuiltin(BOpLte, args) -> renderBinOp(prec, args, " <= ", 5)
    case TBuiltin(BOpGt, args) -> renderBinOp(prec, args, " > ", 5)
    case TBuiltin(BOpGte, args) -> renderBinOp(prec, args, " >= ", 5)
    case TBuiltin(BOpAdd, args) -> renderBinOpP(prec, args, " + ", 6)
    case TBuiltin(BOpSub, args) -> renderBinOpP(prec, args, " - ", 6)
    case TBuiltin(BOpMul, args) -> renderBinOpP(prec, args, " * ", 7)
    case TBuiltin(BOpDiv, args) -> renderBinOpP(prec, args, " / ", 7)
    case TBuiltin(BOpMod, args) -> renderBinOpP(prec, args, " % ", 7)
    case TBuiltin(op, args) -> {
      val opStr = builtinDisplay(op)
      opStr + "(" + joinTermsComma(args) + ")"
    }
    case TApp(name, args, _) -> {
      if args.count == 0 {
        name
      } else {
        name + "(" + joinTermsComma(args) + ")"
      }
    }
    case TIte(c, a, b) -> {
      "if " + renderTerm(0, c) + " then " + renderTerm(0, a) + " else " + renderTerm(0, b)
    }
    case TForall(binders, _, body) -> {
      val bs = formatBinders(binders)
      "forall(" + bs + ") { " + renderTerm(0, body) + " }"
    }
    case TExists(binders, body) -> {
      val bs = formatBinders(binders)
      "exists(" + bs + ") { " + renderTerm(0, body) + " }"
    }
    case TLet(bindings, body) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < bindings.count {
        parts.add(bindings[i].name + " = " + renderTerm(0, bindings[i].term))
        i = i + 1
      }
      "let " + joinSortList(parts) + " in " + renderTerm(0, body)
    }
  }
}

func renderBinOp(prec: in Int, args: in List[Term], op: in String, p: in Int): String {
  if args.count == 2 {
    renderTerm(p, args[0]) + op + renderTerm(p, args[1])
  } else {
    op + "(...)"
  }
}

func renderBinOpP(prec: in Int, args: in List[Term], op: in String, p: in Int): String {
  if args.count == 2 {
    val inner = renderTerm(p, args[0]) + op + renderTerm(p + 1, args[1])
    if prec > p {
      "(" + inner + ")"
    } else {
      inner
    }
  } else {
    op + "(...)"
  }
}

func joinTerms(xs: in List[Term], sep: in String, prec: in Int): String {
  var result = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      result = result + sep
    }
    result = result + renderTerm(prec, xs[i])
    i = i + 1
  }
  result
}

func joinTermsComma(xs: in List[Term]): String {
  joinTerms(xs, ", ", 0)
}

func formatBinders(binders: in List[SortBinder]): String {
  var result = ""
  var i = 0
  while i < binders.count {
    if i > 0 {
      result = result + ", "
    }
    result = result + binders[i].name + ": " + sortDisplay(binders[i].sort)
    i = i + 1
  }
  result
}

pub func prettyGoal(idx: in Int, g: in Goal): String {
  var output = ""
  output = output + "Goal " + intToString(idx) + ": " + g.label + "\n"
  output = output + "  kind:   " + goalKindDisplay(g.kind) + "\n"
  output = output + "  origin: <span>\n"
  if g.symbols.count > 0 {
    output = output + "  symbols:\n"
    var i = 0
    while i < g.symbols.count {
      output = output + renderSymbol(g.symbols[i]) + "\n"
      i = i + 1
    }
  }
  output = output + "  hypotheses:\n"
  if g.hypotheses.count == 0 {
    output = output + "    (none)\n"
  } else {
    var i = 0
    while i < g.hypotheses.count {
      output = output + "    h" + intToString(i + 1) + ": " + prettyTerm(g.hypotheses[i]) + "\n"
      i = i + 1
    }
  }
  output = output + "  conclusion:\n"
  output = output + "    " + prettyTerm(g.conclusion) + "\n"
  output
}

func renderSymbol(s: in SymbolDecl): String {
  match s {
    case DeclUserFun(name, pSorts, rSort) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < pSorts.count {
        parts.add(sortDisplay(pSorts[i]))
        i = i + 1
      }
      "  fun " + name + "(" + joinSortList(parts) + "): " + sortDisplay(rSort)
    }
    case DeclDatatype(name, ctors) -> {
      val ctorParts: List[String] = newList()
      var i = 0
      while i < ctors.count {
        val ctor = ctors[i]
        if ctor.fields.count == 0 {
          ctorParts.add(ctor.name)
        } else {
          val flds: List[String] = newList()
          var j = 0
          while j < ctor.fields.count {
            flds.add(ctor.fields[j].name + ": " + sortDisplay(ctor.fields[j].sort))
            j = j + 1
          }
          ctorParts.add(ctor.name + " { " + joinSortList(flds) + " }")
        }
        i = i + 1
      }
      "  type " + name + " = " + joinCtors(ctorParts)
    }
  }
}

func joinCtors(xs: in List[String]): String {
  var result = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      result = result + " | "
    }
    result = result + xs[i]
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. String conversion helpers for Int/Long/Double.
// ─────────────────────────────────────────────────────────────────────────────
pub func intToString(n: in Int): String {
  n.toString()
}

pub func longToString(n: in Long): String {
  n.toString()
}

pub func doubleToString(f: in Double): String {
  f.toString()
}
