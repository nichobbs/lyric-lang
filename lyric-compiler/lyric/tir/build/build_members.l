//! build_members.l - the members of a file as TIR declarations (docs/70 §6.2): the methods of a
//! record, the members of an `impl` block, the `func`s and entries of a protected type.  Each is a
//! `TFnDecl` whose first parameter is the receiver `self`, passed `in` (declared, or added by the builder when the source leaves it implicit); an entry carries its
//! `when:` clause as `barrier` (D553).  A member of a generic type or `impl` is built with its
//! owner's type parameters first among its own, all `TParam(member symbol, i)` (D579).
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.Resolve
import Lyric.TypeChecker
import Lyric.Tir

/// A member to build: its function (an entry is converted to one), its qualified name, the
/// owner's type name for symbol lookup, the receiver's type, and whether it is an entry.
pub record MemberSite {
  name: String
  fn: FunctionDecl
  ownerName: String
  /// The receiver's type; `None` for a member of a generic owner, whose receiver names the
  /// member's own parameters and is made when the member is built (`genericRecvOf`).
  recv: Option[Ty]
  isEntry: Bool
  /// An `impl` member's target type, for the receiver of a member of a generic `impl`.
  implTarget: Option[TypeExpr]
  /// The binder of the owner's type parameters (none for a type that declares none).
  owner: MemberOwner
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

/// The binder of a type declaration's parameters (none for a type that declares none): a member's
/// own parameters are keyed `key.fn` whether or not the owner is generic, as the checker keys them.
func ownerOf(key: in String, sym: in SymbolId, gps: in Option[GenericParams]): MemberOwner {
  MemberOwner(key = key, sym = sym, names = extractGenericNames(gps))
}

/// The receiver of a member of a type that declares no parameters; `None` for a generic one.
func plainRecv(sym: in SymbolId, owner: in MemberOwner): Option[Ty] {
  if owner.names.count > 0 {
    return None
  }
  Some(value = TNamed(sym = sym, args = newList()))
}

/// The receiver of the member `memberSym` of a generic record or protected type: the type applied
/// to the owner's parameters, which are the member's leading ones.
func genericRecv(typeSym: in SymbolId, memberSym: in SymbolId, count: in Int): Ty {
  val args: List[Ty] = newList()
  var i = 0
  while i < count {
    args.add(TParam(owner = memberSym, index = i))
    i = i + 1
  }
  TNamed(sym = typeSym, args = args)
}

/// Every member of `file` with a body, in source order.
pub func memberSites(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): List[MemberSite] {
  val res: List[MemberSite] = newList()
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  for it in file.items {
    match it.kind {
      case IRecord(decl) -> {
        val tsym = symTableTypeSymbolId(tbl, pkg, decl.name)
        val owner = ownerOf(decl.name, tsym, decl.generics)
        for m in decl.members {
          match m {
            case RMFunc(fn) -> if isSome(fn.body) {
              res.add(
                MemberSite(
                  name = decl.name + "." + fn.name,
                  fn = fn,
                  ownerName = decl.name,
                  recv = plainRecv(tsym, owner),
                  implTarget = None,
                  isEntry = false,
                  owner = owner
                )
              )
            }
            case _ -> ()
          }
        }
      }
      case IProtected(decl) -> {
        val tsym = symTableTypeSymbolId(tbl, pkg, decl.name)
        val owner = ownerOf(decl.name, tsym, decl.generics)
        for m in decl.members {
          match m {
            case PMFunc(fn) -> if isSome(fn.body) {
              res.add(
                MemberSite(
                  name = decl.name + "." + fn.name,
                  fn = fn,
                  ownerName = decl.name,
                  recv = plainRecv(tsym, owner),
                  implTarget = None,
                  isEntry = false,
                  owner = owner
                )
              )
            }
            case PMEntry(e) -> if e.hasBody {
              res.add(
                MemberSite(
                  name = decl.name + "." + e.name,
                  fn = entryAsFunction(e),
                  ownerName = decl.name,
                  recv = plainRecv(tsym, owner),
                  implTarget = None,
                  isEntry = true,
                  owner = owner
                )
              )
            }
            case _ -> ()
          }
        }
      }
      case IImpl(decl) -> {
        val owner = ownerOf(implOwnerKey(decl), SymbolId(id = 0), decl.generics)
        var recv: Option[Ty] = None
        if owner.names.count == 0 {
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
                  ownerName = implDefPath(pkg, decl).segments[0],
                  recv = recv,
                  implTarget = Some(value = decl.target),
                  isEntry = false,
                  owner = owner
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

/// The receiver of a member of a generic type or `impl`, over the member's own parameters.
func genericRecvOf(env: in BuildEnv, tbl: in SymbolTable, site: in MemberSite, memberSym: in SymbolId): Option[Ty] {
  match site.implTarget {
    case Some(target) -> {
      val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
      tyConvBind(env.ctx, site.owner.key, memberSym, site.owner.names)
      gctxPushOwned(gc, site.owner.names, site.owner.key)
      val diag: List[Diagnostic] = newList()
      match tyOfType(env.ctx, resolveType(tbl, gc, diag, target)) {
        case Ok(t) -> Some(value = t)
        case Err(_) -> None
      }
    }
    case None -> Some(value = genericRecv(site.owner.sym, memberSym, site.owner.names.count))
  }
}

/// Build one member in a fresh env sharing `counter`.  `None` carries the reasons in `env.errors`.
pub func buildMember(env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite): Option[TFnDecl] {
  buildMemberWith(env, tbl, pkg, site, false)
}

/// The member's signature as a body-less declaration, for a member whose body does not build.
pub func buildMemberSig(env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite): Option[TFnDecl] {
  buildMemberWith(env, tbl, pkg, site, true)
}

func buildMemberWith(
  env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite, sigOnly: in Bool
): Option[TFnDecl] {
  // A method declares its receiver as an explicit first parameter named `self`; a protected
  // type's members and some `impl` members leave it implicit, and the builder declares it.
  val declaresSelf = site.fn.params.count > 0 and site.fn.params[0].name == "self"
  val sym = match memberSymOf(tbl, pkg, site) {
    case Some(s) -> s
    case None -> {
      noteUncovered(env, "a member with no symbol")
      env.errors.add("I0002: the builder has no symbol for the member: " + site.name)
      return None
    }
  }
  if not declaresSelf {
    var recv = site.recv
    if site.owner.names.count > 0 {
      recv = genericRecvOf(env, tbl, site, sym)
    }
    match recv {
      case Some(t) -> env.recvTy.add(t)
      case None -> {
        noteUncovered(env, "a member whose receiver type cannot be converted")
        env.errors.add("I0002: the receiver type of the member cannot be converted: " + site.name)
        return None
      }
    }
  }
  env.symOverride.add(sym)
  env.memberOwner.add(site.owner)
  if sigOnly {
    buildFnSigDecl(env, site.fn, tbl)
  } else {
    buildFnDecl(env, site.fn, tbl)
  }
}

/// The field `name` of the non-generic protected type `ty`, as the position the type entry gives it.
pub func protectedFieldRef(tbl: in SymbolTable, ty: in Ty, name: in String): Option[FieldRef] {
  match ty {
    case TNamed(sym, _) -> {
      var i = 0
      for f in protectedFieldsOf(tbl, sym) {
        if f.name == name {
          return Some(value = FieldRef(owner = sym, name = name, index = i))
        }
        i = i + 1
      }
      None
    }
    case _ -> None
  }
}

/// A member's bare field name (a protected type's, a record's through an `impl`, an opaque
/// type's): the field of the receiver `self`.
pub record BareField {
  recv: TExpr
  field: FieldRef
}

pub func bareSelfField(env: in BuildEnv, at: in Expr, name: in String): Option[BareField] {
  match lookupLocal(env, "self") {
    case Some(d) -> match fieldRefOf(env, d.ty, name) {
      case Some(f) -> Some(
        value = BareField(
          recv = TExpr(
            id = freshNodeId(env),
            ty = d.ty,
            span = at.span,
            kind = XLocal(local = d.id)
          ),
          field = f
        )
      )
      case None -> None
    }
    case None -> None
  }
}
