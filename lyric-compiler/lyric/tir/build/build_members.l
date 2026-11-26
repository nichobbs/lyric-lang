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
  /// The `invariant:` clauses of the protected type the member belongs to (D509).
  invariants: List[InvariantClause] = newList()
  /// Whether the member is part of the public invariant boundary (D512): a method of a `pub` record, or an `impl`
  /// member (docs/08 §7.1).
  isPublic: Bool = false
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
  MemberOwner(key = key, sym = sym, names = extractGenericNames(gps), valueNames = valueGenericNames(gps))
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
                  owner = owner,
                  isPublic = match it.visibility { case Some(VisPub(_)) -> true; case _ -> false }
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
        val typeInvs: List[InvariantClause] = newList()
        for m in decl.members {
          match m {
            case PMInvariant(inv) -> typeInvs.add(inv)
            case _ -> ()
          }
        }
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
                  owner = owner,
                  invariants = typeInvs
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
                  owner = owner,
                  invariants = typeInvs
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
                  owner = owner,
                  isPublic = true
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

/// The `impl` blocks of `file` as TIR (#7791, D860): each block's DefPath symbol, its own type parameters, the
/// target type and the interface with its arguments, all written over `TParam(owner = the block's symbol, i)`,
/// and the members it declares (`membersByBlock`: the symbols of its built members, keyed by the checker's
/// `implOwnerKey`).  A block with no member has no symbol of its own and is left out, as is one whose types
/// cannot be converted: a pass that needs the block then finds the interface through its members' paths.
pub func buildImplDecls(
  ctx: in TyConvCtx,
  tbl: in SymbolTable,
  file: in SourceFile,
  membersByBlock: in Map[String, List[SymbolId]],
): List[TImplDecl] {
  val res: List[TImplDecl] = newList()
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  for it in file.items {
    match it.kind {
      case IImpl(decl) -> {
        val members = match mapGet(membersByBlock, implOwnerKey(decl)) { case Some(ms) -> ms; case None -> newList() }
        if members.count > 0 {
          match buildImplDecl(tbl, pkg, decl, members) {
            case Some(d) -> res.add(d)
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
  }
  res
}

func buildImplDecl(
  tbl: in SymbolTable, pkg: in String, decl: in ImplDecl, members: in List[SymbolId]
): Option[TImplDecl] {
  val blockKey = implOwnerKey(decl)
  val blockSym = internDefPath(tbl.interner, implDefPath(pkg, decl))
  val names = extractGenericNames(decl.generics)
  val conv = newTyConvCtx(tbl)
  tyConvBind(conv, blockKey, blockSym, names)
  val gc = newGenericContext()
  gctxPushOwned(gc, names, blockKey)
  val diag: List[Diagnostic] = newList()
  val targetTy = match tyOfType(conv, resolveType(tbl, gc, diag, decl.target)) {
    case Ok(t) -> t
    case Err(_) -> return None
  }
  val ifaceTy = resolveType(tbl, gc, diag, TypeExpr(kind = TRef(path = decl.iface.head), span = decl.span))
  val ifaceSym = match ifaceTy { case TyUser(id, _, _) -> id; case _ -> return None }
  val ifaceArgs: List[Ty] = newList()
  for ia in decl.iface.args {
    match ia {
      case TAType(te) -> match tyOfType(conv, resolveType(tbl, gc, diag, te)) {
        case Ok(t) -> ifaceArgs.add(t)
        case Err(_) -> return None
      }
      case TAValue(_) -> return None
    }
  }
  Some(
    value = TImplDecl(
      sym = blockSym,
      typeParams = names,
      target = targetTy,
      iface = ifaceSym,
      ifaceArgs = ifaceArgs,
      members = members,
      span = decl.span
    )
  )
}

/// The interface methods of `file` that declare a default for a parameter, as body-less member sites:
/// the defaults a call through the interface takes (D442).  A generic interface is left out.
pub func interfaceDefaultSites(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): List[MemberSite] {
  val res: List[MemberSite] = newList()
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  for it in file.items {
    match it.kind {
      case IInterface(decl) -> {
        val tsym = symTableTypeSymbolId(tbl, pkg, decl.name)
        val owner = ownerOf(decl.name, tsym, decl.generics)
        if owner.names.count == 0 {
          for m in decl.members {
            match m {
              case IMSig(sig) -> {
                var declares = false
                for p in sig.params {
                  if isSome(p.dflt) {
                    declares = true
                  }
                }
                if declares {
                  res.add(
                    MemberSite(
                      name = decl.name + "." + sig.name,
                      fn = FunctionDecl(
                        docComments = sig.docComments,
                        annotations = newList(),
                        visibility = None,
                        isAsync = sig.isAsync,
                        name = sig.name,
                        generics = sig.generics,
                        params = sig.params,
                        ret = sig.ret,
                        whereClause = sig.whereClause,
                        contracts = sig.contracts,
                        body = None,
                        span = sig.span
                      ),
                      ownerName = decl.name,
                      recv = plainRecv(tsym, owner),
                      implTarget = None,
                      isEntry = false,
                      owner = owner
                    )
                  )
                }
              }
              case _ -> ()
            }
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
  buildMemberWith(env, tbl, pkg, site, 0)
}

/// The member's signature as a body-less declaration, for a member whose body does not build.
pub func buildMemberSig(env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite): Option[TFnDecl] {
  buildMemberWith(env, tbl, pkg, site, 1)
}

/// The member's signature with its parameters' defaults, as a body-less declaration.
pub func buildMemberDefaults(
  env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite
): Option[TFnDecl] {
  buildMemberWith(env, tbl, pkg, site, 2)
}

func buildMemberWith(
  env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite, mode: in Int
): Option[TFnDecl] {
  // Inside a member, `Self` is the type the member belongs to: an `impl`'s target (D476), a
  // record's or protected type's own type (D521).
  var pushed = false
  val target = if site.owner.names.count > 0 {
    match memberSymOf(tbl, pkg, site) {
      case Some(s) -> genericRecvOf(env, tbl, site, s)
      case None -> None
    }
  } else {
    site.recv
  }
  match target {
    case Some(t) -> {
      env.ctx.implSelf.add(t)
      pushed = true
    }
    case None -> ()
  }
  val res = buildMemberInner(env, tbl, pkg, site, mode)
  if pushed {
    env.ctx.implSelf.removeAt(env.ctx.implSelf.count - 1)
  }
  res
}

func buildMemberInner(
  env: in BuildEnv, tbl: in SymbolTable, pkg: in String, site: in MemberSite, mode: in Int
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
  for inv in site.invariants {
    env.memberInvs.add(inv)
  }
  if site.isPublic {
    env.memberPublic.add(true)
  }
  if mode == 1 {
    buildFnSigDecl(env, site.fn, tbl)
  } else if mode == 2 {
    buildFnDefaultsDecl(env, site.fn, tbl)
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
