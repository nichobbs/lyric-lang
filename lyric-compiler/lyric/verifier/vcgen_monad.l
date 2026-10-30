//! verifier/vcgen_monad.l — Result and Option values.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// ─────────────────────────────────────────────────────────────────────────────
// `Result` and `Option` values (#8108).
// ─────────────────────────────────────────────────────────────────────────────
record MonadAccess {
  term: Term
  sides: List[Term]
}

// `r.isOk`, `r.isErr`, `r.value`, `r.error`, `o.isSome`, `o.isNone`,
// `o.value`.  Reading the payload of the other case traps, so `.value` and
// `.error` carry the obligation that the value is that case.
func monadMember(r: in Term, member: in String): Option[MonadAccess] {
  val sides: List[Term] = newList()
  val s = sortOf(r)
  val ctor = pendingCtorName(r)
  if ctor.length > 0 {
    val args = pendingCtorArgs(r)
    if member == "isOk" and (ctor == "Ok" or ctor == "Err") {
      return Some(value = MonadAccess(term = boolLit(ctor == "Ok"), sides = sides))
    }
    if member == "isErr" and (ctor == "Ok" or ctor == "Err") {
      return Some(value = MonadAccess(term = boolLit(ctor == "Err"), sides = sides))
    }
    if member == "isSome" and (ctor == "Some" or ctor == "None") {
      return Some(value = MonadAccess(term = boolLit(ctor == "Some"), sides = sides))
    }
    if member == "isNone" and (ctor == "Some" or ctor == "None") {
      return Some(value = MonadAccess(term = boolLit(ctor == "None"), sides = sides))
    }
    if member == "value" and (ctor == "Ok" or ctor == "Some") and args.count == 1 {
      return Some(value = MonadAccess(term = args[0], sides = sides))
    }
    if member == "error" and ctor == "Err" and args.count == 1 {
      return Some(value = MonadAccess(term = args[0], sides = sides))
    }
    return None
  }
  if isResultSort(s) {
    if member == "isOk" {
      return Some(value = MonadAccess(term = mkIsOk(r), sides = sides))
    }
    if member == "isErr" {
      return Some(value = MonadAccess(term = mkNot(mkIsOk(r)), sides = sides))
    }
    if member == "value" {
      sides.add(mkIsOk(r))
      return Some(value = MonadAccess(term = mkResultValue(r), sides = sides))
    }
    if member == "error" {
      sides.add(mkNot(mkIsOk(r)))
      return Some(value = MonadAccess(term = mkResultError(r), sides = sides))
    }
    return None
  }
  if isOptionSort(s) {
    if member == "isSome" {
      return Some(value = MonadAccess(term = mkIsSome(r), sides = sides))
    }
    if member == "isNone" {
      return Some(value = MonadAccess(term = mkNot(mkIsSome(r)), sides = sides))
    }
    if member == "value" {
      sides.add(mkIsSome(r))
      return Some(value = MonadAccess(term = mkOptionValue(r), sides = sides))
    }
    return None
  }
  None
}

func boolLit(b: in Bool): Term {
  if b {
    trueT()
  } else {
    falseT()
  }
}

// A call the file does not declare to one of `Std.Core`'s constructors or
// case tests: `Ok(v)`, `Err(e)`, `Some(v)` — positional, or named by the
// case's field, `Ok(value = v)`, `Err(error = e)` — and `isOk(r)`,
// `isErr(r)`, `isSome(o)`, `isNone(o)`.
func monadCall(name: in String, args: in List[CallArg], terms: in List[Term]): Option[Term] {
  if args.count != 1 or terms.count != 1 {
    return None
  }
  val field = if name == "Err" { "error" } else { "value" }
  val fits = match args[0] {
    case CANamed(argName, _, _) -> (name == "Ok" or name == "Err" or name == "Some") and argName == field
    case CAPositional(_) -> true
  }
  if not fits {
    return None
  }
  val t = terms[0]
  if name == "Ok" or name == "Err" or name == "Some" {
    return Some(value = mkPendingCtor(name, termList1(t)))
  }
  if name == "isOk" or name == "isErr" or name == "isSome" or name == "isNone" {
    match monadMember(t, name) {
      case Some(acc) -> Some(value = acc.term)
      case None -> None
    }
  } else {
    None
  }
}

func noPins(): List[Bool] {
  val none: List[Bool] = newList()
  none
}

// The top-level type names a file declares.
pub func declaredTypeNames(file: in SourceFile): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < file.items.count {
    val declared = match file.items[i].kind {
      case ITypeAlias(d) -> d.name
      case IDistinctType(d) -> d.name
      case IRecord(d) -> d.name
      case IExposedRec(d) -> d.name
      case IUnion(d) -> d.name
      case IEnum(d) -> d.name
      case IOpaque(d) -> d.name
      case IProtected(d) -> d.name
      case IInterface(d) -> d.name
      case IExternType(d) -> d.name
      case IConfig(d) -> d.name
      case _ -> ""
    }
    if declared.length > 0 {
      names.add(declared)
    }
    i = i + 1
  }
  names
}
