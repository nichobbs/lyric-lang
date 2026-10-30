//! verifier/vcgen_equality.l — which terms the verifier may compare with ==, and structural equality keys.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// Whether `t` holds an `==` or `!=` whose operands the verifier's equality
// does not model in `env` (`equalityModelled`): a callee's contract over a
// type parameter, instantiated with an argument such as a function value.
func unmodelledEquality(env: in VEnv, t: in Term): Bool {
  match t {
    case TVar(_, _) -> false
    case TLit(_, _) -> false
    case TBuiltin(op, args) -> {
      val isEq = match op { case BOpEq | BOpNeq -> true; case _ -> false }
      if isEq and args.count == 2 and (not equalityModelled(env, args[0]) or not equalityModelled(env, args[1])) {
        return true
      }
      anyUnmodelledEquality(env, args)
    }
    case TApp(_, args, _) -> anyUnmodelledEquality(env, args)
    case TLet(bs, body) -> {
      var i = 0
      while i < bs.count {
        if unmodelledEquality(env, bs[i].term) {
          return true
        }
        i = i + 1
      }
      unmodelledEquality(env, body)
    }
    case TIte(c, a, b) -> unmodelledEquality(env, c) or unmodelledEquality(env, a) or unmodelledEquality(env, b)
    case TForall(_, _, body) -> unmodelledEquality(env, body)
    case TExists(_, body) -> unmodelledEquality(env, body)
  }
}

func anyUnmodelledEquality(env: in VEnv, ts: in List[Term]): Bool {
  var i = 0
  while i < ts.count {
    if unmodelledEquality(env, ts[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// The key under which `valueTypes` records that the file declares the union
// `name`.
func unionKey(name: in String): String {
  "!union!" + name
}

// The key under which `valueTypes` records that `==` on the file's type
// `name` compares field by field (or case and payload, for a union) on
// every target, so the verifier's datatype equality is the runtime's.
func structuralEqualityKey(name: in String): String {
  "!structeq!" + name
}

// Whether `anns` hold `@derive(Equals)`.
func derivesEquals(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val ann = anns[i]
    if ann.name.segments.count == 1 and ann.name.segments[0] == "derive" {
      var j = 0
      while j < ann.args.count {
        val named = match ann.args[j] { case ABare(nm, _) -> nm; case AAName(nm, _, _) -> nm; case _ -> "" }
        if named == "Equals" {
          return true
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  false
}

// Record each type the file declares whose `==` is structural (D164,
// D172) and over leaves the verifier models (`equalityModelledSort`),
// resolved to a fixed point: an enum; a non-generic union; a non-generic
// record with no `var` field, or one that derives `Equals`.  A record with
// a `var` field that does not derive `Equals` compares by identity; a
// generic type, a protected, opaque, interface or extern type, an alias,
// and a type with a function-typed field are never listed.  The fixed
// point is the greatest one, so a recursive record (`next: Option[Node]`)
// is listed when its other fields allow.
func addStructuralEqualityTypes(
  file: in SourceFile,
  distincts: in Map[String, TypeExpr],
  valueTypes: in Map[String, Bool],
): Unit {
  val names: List[String] = newList()
  val fieldTypes: List[List[TypeExpr]] = newList()
  var i = 0
  while i < file.items.count {
    val anns = file.items[i].annotations
    match file.items[i].kind {
      case IEnum(d) -> {
        if not valueTypes.containsKey(structuralEqualityKey(d.name)) {
          valueTypes.add(structuralEqualityKey(d.name), true)
        }
      }
      case IRecord(d) -> {
        if isNone(d.generics) and (not recordHasVarField(d) or derivesEquals(anns)) {
          names.add(d.name)
          fieldTypes.add(recordFieldTypes(d))
        }
      }
      case IExposedRec(d) -> {
        if isNone(d.generics) and (not recordHasVarField(d) or derivesEquals(anns)) {
          names.add(d.name)
          fieldTypes.add(recordFieldTypes(d))
        }
      }
      case IUnion(d) -> {
        if isNone(d.generics) {
          val tys: List[TypeExpr] = newList()
          var ci = 0
          while ci < d.cases.count {
            var fi = 0
            while fi < d.cases[ci].fields.count {
              match d.cases[ci].fields[fi] {
                case UFNamed(_, ty, _) -> tys.add(ty)
                case UFPos(ty, _) -> tys.add(ty)
              }
              fi = fi + 1
            }
            ci = ci + 1
          }
          names.add(d.name)
          fieldTypes.add(tys)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  val alive: List[Bool] = newList()
  var ai = 0
  while ai < names.count {
    alive.add(true)
    ai = ai + 1
  }
  var changed = true
  while changed {
    changed = false
    // The enums, and every candidate not yet ruled out.
    val assumed: Map[String, Bool] = newMap()
    var ki = 0
    while ki < file.items.count {
      match file.items[ki].kind {
        case IEnum(d) -> {
          if not assumed.containsKey(structuralEqualityKey(d.name)) {
            assumed.add(structuralEqualityKey(d.name), true)
          }
        }
        case _ -> ()
      }
      ki = ki + 1
    }
    var ni = 0
    while ni < names.count {
      if alive[ni] and not assumed.containsKey(structuralEqualityKey(names[ni])) {
        assumed.add(structuralEqualityKey(names[ni]), true)
      }
      ni = ni + 1
    }
    ni = 0
    while ni < names.count {
      if alive[ni] {
        val tys = fieldTypes[ni]
        var ti = 0
        while ti < tys.count {
          if alive[ni] and not equalityModelledSort(assumed, noTypeParams(), sortOfTypeExprWith(distincts, tys[ti]).sort, 0) {
            alive[ni] = false
            changed = true
          }
          ti = ti + 1
        }
      }
      ni = ni + 1
    }
  }
  var ni = 0
  while ni < names.count {
    if alive[ni] and not valueTypes.containsKey(structuralEqualityKey(names[ni])) {
      valueTypes.add(structuralEqualityKey(names[ni]), true)
    }
    ni = ni + 1
  }
}

func recordHasVarField(d: in RecordDecl): Bool {
  var mi = 0
  while mi < d.members.count {
    match d.members[mi] {
      case RMField(fld) -> {
        if fld.isMutable {
          return true
        }
      }
      case _ -> ()
    }
    mi = mi + 1
  }
  false
}

func recordFieldTypes(d: in RecordDecl): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  var mi = 0
  while mi < d.members.count {
    match d.members[mi] {
      case RMField(fld) -> tys.add(fld.ty)
      case _ -> ()
    }
    mi = mi + 1
  }
  tys
}

// Whether `==` between two values like `t` means what the verifier's
// equality says on every target.  It does not where a value may be or
// hold a function (a delegate compares its method and target on .NET, a
// lambda its reference on the JVM, and one function named twice may be two
// objects), where `==` is identity (a mutable record, a protected object),
// where the type is a generic parameter, a host collection or a type whose
// equality differs between targets, or where the type is not known — a
// module-level name with no declared type, a qualified path, an unannotated
// lambda parameter (#8109).
// A type parameter of the generic being translated (`env.typeParams`) is
// an opaque equivalence: whatever `==` on its binding is — structural,
// identity, a delegate's — it is reflexive, symmetric and transitive, as
// the solver's equality is.  (`Float`/`Double` are reals throughout,
// #8141.)  What a call binds it to is checked where the contract is
// instantiated (`unmodelledEquality`).
func equalityModelled(env: in VEnv, t: in Term): Bool {
  if pendingCtorName(t).length > 0 {
    val args = pendingCtorArgs(t)
    var i = 0
    while i < args.count {
      if not equalityModelled(env, args[i]) {
        return false
      }
      i = i + 1
    }
    return true
  }
  equalityModelledSort(env.valueTypes, env.typeParams, sortOf(t), 0)
}

func allEqualityModelled(env: in VEnv, ts: in List[Term]): Bool {
  var i = 0
  while i < ts.count {
    if not equalityModelled(env, ts[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func equalityModelledSort(
  valueTypes: in Map[String, Bool], typeParams: in List[String], s: in Sort, depth: in Int
): Bool {
  if depth > 32 {
    return false
  }
  match s {
    case SBool -> true
    case SInt -> true
    case SBitVec(_) -> true
    case SFloat32 -> true
    case SFloat64 -> true
    case SString -> true
    case SDatatype(n, args) -> {
      if n == unitSortName() {
        return true
      }
      if isTupleSortName(n) or isResultSort(s) or isOptionSort(s) {
        var i = 0
        while i < args.count {
          if not equalityModelledSort(valueTypes, typeParams, args[i], depth + 1) {
            return false
          }
          i = i + 1
        }
        return true
      }
      args.count == 0 and (valueTypes.containsKey(structuralEqualityKey(n)) or typeParams.contains(n))
    }
    // An array compares element by element; a slice compares by reference
    // on dotnet and by value elsewhere, so `==` on one has no faithful
    // translation (#8218).
    case SSlice(_) -> false
    case SArray(e) -> equalityModelledSort(valueTypes, typeParams, e, depth + 1)
    // A value the verifier does not model is a symbol of its own — one
    // evaluation's — or the result of a method it does not model (#8110);
    // only the symbols named after the source, which one name evaluated
    // twice would share, have an unknown type.
    case SUninterp(n) -> not (n == "Function" or n == "lambda" or n == "lambdaparam" or n == "path" or n.startsWith("global!"))
  }
}
