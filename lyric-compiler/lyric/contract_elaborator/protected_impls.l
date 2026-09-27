//! protected_impls.l — `impl Iface for P` where `P` is a protected type (#7457).
//!
//! A protected type's state is reachable only through its locked members
//! (§7.5), so an interface method implemented for one must run under the
//! same instance lock, wake barrier waiters on exit, and re-check the type's
//! invariants — exactly what an `entry` does.  Rather than teach every
//! backend a second locked-method path, this pass moves each impl method
//! into the protected type as an `entry` member before elaboration.  The
//! existing protected-type machinery then does the rest: the barrier
//! protocol and invariant asserts here in the elaborator, and the lock in
//! each backend.  The impl block stays behind with no methods; backends
//! still emit the interface relation for it (an InterfaceImpl row on MSIL,
//! an `implements` entry on the JVM) and dispatch binds to the moved
//! member by name and signature.
//!
//! The interface's own `requires:`/`ensures:` clauses (#7223) are attached
//! to the moved entry, since `elaborateImplDecl` no longer sees the method.
//!
//! The type checker (`checkImplOnProtected`, T0135/T0136) has already
//! rejected the shapes this move cannot represent: an impl in another
//! package than `P`, a generic `P` or impl, an `async` or method-generic
//! impl method, and an impl method named like one of `P`'s own members.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// The protected type an impl block targets, when it is declared in `items`,
// is non-generic, and the impl itself is non-generic.
func protectedImplTarget(decl: in ImplDecl, protectedNames: in Map[String, Bool]): Option[String] {
  match decl.generics {
    case Some(_) -> return None
    case None -> ()
  }
  match decl.target.kind {
    case TRef(path) -> {
      if path.segments.count == 1 and protectedNames.containsKey(path.segments[0]) {
        Some(value = path.segments[0])
      } else {
        None
      }
    }
    case _ -> None
  }
}

func protectedSelfTypeRef(name: in String, sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)
}

// `Self` in an impl signature names the target; inside the protected type
// there is no `Self` binding, so spell it out.
func substProtectedSelf(te: in TypeExpr, name: in String): TypeExpr {
  match te.kind {
    case TSelf -> protectedSelfTypeRef(name, te.span)
    case TParen(inner) -> TypeExpr(kind = TParen(inner = substProtectedSelf(inner, name)), span = te.span)
    case _ -> te
  }
}

func implMethodAsEntry(
  fn: in FunctionDecl, body: in FunctionBody, extra: in List[ContractClause], target: in String
): EntryDecl {
  val params: List[Param] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    params.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substProtectedSelf(p.ty, target),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  val ret: Option[TypeExpr] = match fn.ret {
    case Some(r) -> Some(value = substProtectedSelf(r, target))
    case None -> None
  }
  val contracts: List[ContractClause] = newList()
  var c = 0
  while c < extra.count {
    contracts.add(extra[c])
    c = c + 1
  }
  var d = 0
  while d < fn.contracts.count {
    contracts.add(fn.contracts[d])
    d = d + 1
  }
  EntryDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    name = fn.name,
    params = params,
    ret = ret,
    contracts = contracts,
    body = body,
    span = fn.span
  )
}

/// Move the methods of every `impl` block that targets a protected type
/// declared in `items` into that type as `entry` members, leaving each such
/// impl block with only its non-method members.  Items keep their order.
pub func mergeProtectedImpls(items: in List[Item], ifaces: in Map[String, InterfaceDecl]): List[Item] {
  val protectedNames: Map[String, Bool] = newMap()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IProtected(pd) -> match pd.generics {
        case None -> if not protectedNames.containsKey(pd.name) {
          protectedNames.add(pd.name, true)
        }
        case Some(_) -> ()
      }
      case _ -> ()
    }
    i = i + 1
  }
  if protectedNames.count == 0 {
    return items
  }

  // Moved members per protected type, in impl-then-method source order.
  val movedOwners: List[String] = newList()
  val moved: List[ProtectedMember] = newList()
  val rewritten: List[Item] = newList()
  i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IImpl(decl) -> match protectedImplTarget(decl, protectedNames) {
        case Some(target) -> {
          val segs = decl.iface.head.segments
          val ifaceOpt: Option[InterfaceDecl] = if segs.count == 0 { None } else { mapGet(ifaces, segs[segs.count - 1]) }
          val kept: List[ImplMember] = newList()
          var m = 0
          while m < decl.members.count {
            match decl.members[m] {
              case IMplFunc(fn) -> match fn.body {
                case Some(body) -> {
                  val extra: List[ContractClause] = match ifaceOpt {
                    case Some(iface) -> match interfaceMemberContract(iface, fn.name) {
                      case Some(sig) -> inheritedClauses(sig, fn)
                      case None -> newList()
                    }
                    case None -> newList()
                  }
                  movedOwners.add(target)
                  moved.add(PMEntry(entryDecl = implMethodAsEntry(fn, body, extra, target)))
                }
                case None -> kept.add(decl.members[m])
              }
              case other -> kept.add(other)
            }
            m = m + 1
          }
          rewritten.add(
            withKind(
              it,
              IImpl(
                decl = ImplDecl(
                  generics = decl.generics,
                  iface = decl.iface,
                  target = decl.target,
                  whereClause = decl.whereClause,
                  members = kept,
                  span = decl.span
                )
              )
            )
          )
        }
        case None -> rewritten.add(it)
      }
      case _ -> rewritten.add(it)
    }
    i = i + 1
  }
  if moved.count == 0 {
    return items
  }

  val result: List[Item] = newList()
  i = 0
  while i < rewritten.count {
    val it = rewritten[i]
    match it.kind {
      case IProtected(pd) -> {
        val members: List[ProtectedMember] = newList()
        var k = 0
        while k < pd.members.count {
          members.add(pd.members[k])
          k = k + 1
        }
        var added = 0
        var j = 0
        while j < moved.count {
          if movedOwners[j] == pd.name {
            members.add(moved[j])
            added = added + 1
          }
          j = j + 1
        }
        if added == 0 {
          result.add(it)
        } else {
          result.add(
            withKind(
              it,
              IProtected(
                decl = ProtectedTypeDecl(
                  name = pd.name,
                  generics = pd.generics,
                  whereClause = pd.whereClause,
                  members = members,
                  span = pd.span
                )
              )
            )
          )
        }
      }
      case _ -> result.add(it)
    }
    i = i + 1
  }
  result
}
