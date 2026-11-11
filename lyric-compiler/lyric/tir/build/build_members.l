//! build_members.l - the members of a file as TIR declarations (docs/70 §6.2): the methods of a
//! record, the members of an `impl` block, the `func`s and entries of a protected type.  Each is a
//! `TFnDecl` whose first parameter is the receiver `self`, passed `in` (declared, or added by the builder when the source leaves it implicit); an entry carries its
//! `when:` clause as `barrier` (D553).  A member of a generic type or `impl` is not built yet and
//! is counted as the uncovered kind "a method of a generic type".
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Tir

/// A member to build: its function (an entry is converted to one), its qualified name, the
/// owner's type name for symbol lookup, the receiver's type, and whether it is an entry.
pub record MemberSite {
  name: String
  fn: FunctionDecl
  ownerName: String
  recv: Option[Ty]
  isEntry: Bool
  isGenericOwnerSite: Bool
}

/// An entry as the function the builder builds: its `when:` clause stays among the contracts.
func entryAsFunction(e: in EntryDecl): FunctionDecl {
  FunctionDecl(
    docComments = e.docComments,
    annotations = e.annotations,
    visibility = e.visibility,
    isAsync = false,
    name = e.name,
    generics = None,
    params = e.params,
    ret = e.ret,
    whereClause = None,
    contracts = e.contracts,
    body = Some(value = e.body),
    span = e.span
  )
}

func isGenericOwner(gps: in Option[GenericParams]): Bool {
  match gps {
    case Some(_) -> true
    case None -> false
  }
}

/// The type of a non-generic type declared in this package: the receiver of its members.
func ownType(tbl: in SymbolTable, pkg: in String, name: in String): Ty {
  TNamed(sym = symTableTypeSymbolId(tbl, pkg, name), args = newList())
}

/// Every member of `file` with a body, in source order.
pub func memberSites(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): List[MemberSite] {
  val res: List[MemberSite] = newList()
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  for it in file.items {
    match it.kind {
      case IRecord(decl) -> {
        val isGenericOwnerSite = isGenericOwner(decl.generics)
        for m in decl.members {
          match m {
            case RMFunc(fn) -> if isSome(fn.body) {
              res.add(
                MemberSite(
                  name = decl.name + "." + fn.name,
                  fn = fn,
                  ownerName = decl.name,
                  recv = if isGenericOwnerSite { None } else { Some(value = ownType(tbl, pkg, decl.name)) },
                  isEntry = false,
                  isGenericOwnerSite = isGenericOwnerSite
                )
              )
            }
            case _ -> ()
          }
        }
      }
      case IProtected(decl) -> {
        val isGenericOwnerSite = isGenericOwner(decl.generics)
        for m in decl.members {
          match m {
            case PMFunc(fn) -> if isSome(fn.body) {
              res.add(
                MemberSite(
                  name = decl.name + "." + fn.name,
                  fn = fn,
                  ownerName = decl.name,
                  recv = if isGenericOwnerSite { None } else { Some(value = ownType(tbl, pkg, decl.name)) },
                  isEntry = false,
                  isGenericOwnerSite = isGenericOwnerSite
                )
              )
            }
            case PMEntry(e) -> if e.hasBody {
              res.add(
                MemberSite(
                  name = decl.name + "." + e.name,
                  fn = entryAsFunction(e),
                  ownerName = decl.name,
                  recv = if isGenericOwnerSite { None } else { Some(value = ownType(tbl, pkg, decl.name)) },
                  isEntry = true,
                  isGenericOwnerSite = isGenericOwnerSite
                )
              )
            }
            case _ -> ()
          }
        }
      }
      case IImpl(decl) -> {
        val isGenericOwnerSite = isGenericOwner(decl.generics)
        var recv: Option[Ty] = None
        if not isGenericOwnerSite {
          val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
          val diag: List[Diagnostic] = newList()
          match tyOfType(ctx, resolveType(tbl, gc, diag, decl.target)) {
            case Ok(t) -> {
              recv = Some(value = t)
            }
            case Err(_) -> ()
          }
        }
        for m in decl.members {
          match m {
            case IMplFunc(fn) -> if isSome(fn.body) {
              res.add(
                MemberSite(
                  name = "impl." + fn.name,
                  fn = fn,
                  ownerName = "",
                  recv = recv,
                  isEntry = false,
                  isGenericOwnerSite = isGenericOwnerSite
                )
              )
            }
            case IMplAssoc(_) -> ()
          }
        }
      }
      case _ -> ()
    }
  }
  res
}

/// The symbol of `site`, which the resolver gave its declaration.
pub func memberSymOf(tbl: in SymbolTable, pkg: in String, site: in MemberSite): Option[SymbolId] {
  symTableMethodDeclId(tbl, pkg, site.fn.name, site.fn.span, site.ownerName)
}

/// Build one member in a fresh env sharing `counter`.  `None` carries the reasons in `env.errors`.
pub func buildMember(env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite): Option[TFnDecl] {
  if site.isGenericOwnerSite {
    noteUncovered(env, "a method of a generic type")
    env.errors.add("I0002: the builder does not build a method of a generic type: " + site.name)
    return None
  }
  // A method declares its receiver as an explicit first parameter named `self`; a protected
  // type's members and some `impl` members leave it implicit, and the builder declares it.
  val declaresSelf = site.fn.params.count > 0 and site.fn.params[0].name == "self"
  if not declaresSelf {
    match site.recv {
      case Some(t) -> env.recvTy.add(t)
      case None -> {
        noteUncovered(env, "a member whose receiver type cannot be converted")
        env.errors.add("I0002: the receiver type of the member cannot be converted: " + site.name)
        return None
      }
    }
  }
  val sym = match memberSymOf(tbl, pkg, site) {
    case Some(s) -> s
    case None -> {
      noteUncovered(env, "a member with no symbol")
      env.errors.add("I0002: the builder has no symbol for the member: " + site.name)
      return None
    }
  }
  env.symOverride.add(sym)
  buildFnDecl(env, site.fn, tbl)
}
