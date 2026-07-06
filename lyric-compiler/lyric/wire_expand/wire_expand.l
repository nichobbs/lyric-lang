//! wire_expand.l — Lyric.WireExpand
//!
//! Front-end AST expansion for docs/58 (D121): config templates,
//! `contributes[T]` ordered multi-value wire bindings, and wire templates.
//! Runs BEFORE type checking on both backends (Msil.Bridge / Jvm.Bridge),
//! so every docs/58 construct is rewritten into ordinary items and plain
//! wire members and neither backend needs docs/58-specific codegen:
//!
//!   1. `pub config Name { fields }` (template declaration) is replaced by
//!      a synthesised `pub record Name { fields }` — the template's field
//!      shape as a first-class nominal type.  The declaring package gets no
//!      env-var-backed config block for a template; only instantiations do.
//!   2. `config Local from Pkg.Template { overrides }` (module level or
//!      hoisted from a wire body) materialises an ordinary `config Local`
//!      block: template fields in template order, override defaults
//!      applied, env vars derived from the LOCAL name per docs/25 §5.
//!   3. `contributes[T] name = expr` entries become plain wire locals plus
//!      one synthesised `val <T>: List[T] = [entries…]` member per
//!      collection, ordered by declaration adjusted by `wraps:`/`inside:`.
//!   4. `include Pkg.Module { adjustments }` splices a collected `pub wire`
//!      template into the including wire: `@provided` inputs are
//!      name-substituted, non-exposed members get collision-proof
//!      `__incl<N>_` internal names, exposed / contributes / config-
//!      instance names enter the includer's scope bare (or alias-qualified
//!      via `include … as Alias`), and replace/remove adjustments are
//!      gated by the template's `overridable` allow-list.
//!   5. `pub wire` template items are dropped from the output file (they
//!      are never bootstrapped as the declaring package's own graph).
//!
//! Inside wire member initialisers, a value-position reference to a
//! config-template instantiation (`Web.create(staticFiles: Assets)`)
//! is rewritten to a record construction of the template's synthesised
//! record type, reading each field through the instantiation's ordinary
//! config statics (`Assets(root = Assets.root, …)` shape).  Field access
//! (`Assets.root`) is left untouched — it stays ordinary config access.
//!
//! Diagnostics: W0010–W0026 (see docs/03-decision-log.md D121 for the
//! full table).
package Lyric.WireExpand

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Collected templates.
// ─────────────────────────────────────────────────────────────────────────────
/// One `pub wire` template collected before expansion, keyed by FQN
/// (`pkgName + "." + decl.name`).
pub record CollectedWireTemplate {
  decl: WireDecl
  pkgName: String
}

/// One `pub config` template collected before expansion, keyed by FQN.
pub record CollectedConfigTemplate {
  decl: ConfigDecl
  pkgName: String
}

/// Collect every `pub wire` and `pub config` template from `items` into
/// the two destination maps.  Mirrors `Lyric.Weaver.collectAspectTemplates`:
/// called once per package (project files and source-dependency files)
/// before any file is expanded, so cross-package `include` / `from`
/// references resolve.  Non-`pub` wires and configs are not templates and
/// are never collected.
pub func collectWireTemplates(
  items: in List[Item],
  pkgName: in String,
  destWires: in Map[String, CollectedWireTemplate],
  destConfigs: in Map[String, CollectedConfigTemplate],
): Unit {
  var i = 0
  while i < items.count {
    val it = items[i]
    val isPub = match it.visibility { case Some(_) -> true; case None -> false }
    if isPub {
      match it.kind {
        case IWire(decl) -> {
          val fqn = pkgName + "." + decl.name
          if not destWires.containsKey(fqn) {
            destWires.add(fqn, CollectedWireTemplate(decl = decl, pkgName = pkgName))
          }
        }
        case IConfig(decl) -> {
          match decl.from {
            case Some(_) -> {
            }
            case None -> {
              val fqn = pkgName + "." + decl.name
              if not destConfigs.containsKey(fqn) {
                destConfigs.add(fqn, CollectedConfigTemplate(decl = decl, pkgName = pkgName))
              }
            }
          }
        }
        case _ -> {
        }
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Small utilities.
// ─────────────────────────────────────────────────────────────────────────────
func dottedPathWE(p: in ModulePath): String {
  var s = ""
  var i = 0
  while i < p.segments.count {
    if i > 0 {
      s = s + "."
    }
    s = s + p.segments[i]
    i = i + 1
  }
  s
}

func lastSegmentWE(p: in ModulePath): String {
  if p.segments.count == 0 {
    ""
  } else {
    p.segments[p.segments.count - 1]
  }
}

/// Render a type expression for equality comparison and collection naming.
/// Config-template field types are simple named types, but cover the
/// compound shapes so a mismatch never falsely compares equal.
func typeToStrWE(t: in TypeExpr): String {
  match t.kind {
    case TRef(path) -> dottedPathWE(path)
    case TGenericApp(head, args) -> {
      var s = dottedPathWE(head) + "["
      var i = 0
      while i < args.count {
        if i > 0 {
          s = s + ", "
        }
        match args[i] {
          case TAType(ty) -> {
            s = s + typeToStrWE(ty)
          }
          case _ -> {
            s = s + "?"
          }
        }
        i = i + 1
      }
      s + "]"
    }
    case TSlice(element) -> "slice[" + typeToStrWE(element) + "]"
    case TTuple(types) -> {
      var s = "("
      var i = 0
      while i < types.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + typeToStrWE(types[i])
        i = i + 1
      }
      s + ")"
    }
    case TNullable(inner) -> typeToStrWE(inner) + "?"
    case _ -> "<type>"
  }
}

/// The simple (last-segment) name of a `contributes[T]` interface type —
/// the bare identifier the collection resolves under.
func collectionNameOf(t: in TypeExpr): String {
  match t.kind {
    case TRef(path) -> lastSegmentWE(path)
    case TGenericApp(head, _) -> lastSegmentWE(head)
    case _ -> "<collection>"
  }
}

func listContainsWE(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

/// Template lookup: try the `from`/`include` path as written, then retry
/// with the consuming package's prefix so a same-package short form
/// (`from StaticFiles`) resolves — mirrors `Lyric.Weaver.lookupFromTemplate`.
func lookupWireTemplate(
  templates: in Map[String, CollectedWireTemplate], fqn: in String, pkgName: in String
): Option[CollectedWireTemplate] {
  match mapGet(templates, fqn) {
    case Some(t) -> Some(value = t)
    case None -> {
      if pkgName.length > 0 {
        mapGet(templates, pkgName + "." + fqn)
      } else {
        None
      }
    }
  }
}

func lookupConfigTemplate(
  templates: in Map[String, CollectedConfigTemplate], fqn: in String, pkgName: in String
): Option[CollectedConfigTemplate] {
  match mapGet(templates, fqn) {
    case Some(t) -> Some(value = t)
    case None -> {
      if pkgName.length > 0 {
        mapGet(templates, pkgName + "." + fqn)
      } else {
        None
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Expression substitution.
// ─────────────────────────────────────────────────────────────────────────────
/// Name-based substitution over a wire member initialiser:
///   - a single-segment `EPath([n])` with `n` in `renames` becomes the
///     mapped replacement expression (provided-input mapping, internal
///     `__incl<N>_` renames, and the config-instance record-construction
///     rewrite all use this);
///   - `EMember(EPath([r]), m)` with `"r/m"` in `memberRewrites` becomes a
///     bare `EPath([newName])` (alias-qualified access to an included
///     module's exposed member);
///   - `EMember(EPath([r]), m)` with `r` in `configRecvs` is left intact —
///     that is ordinary config-static field access, which must NOT have
///     its receiver rewritten to a record construction.
record SubstCtx {
  renames: Map[String, Expr]
  memberRewrites: Map[String, String]
  // Receiver-only renames: `EMember(EPath([old]), f)` becomes
  // `EMember(EPath([new]), f)` with the member untouched — the
  // alias-prefixed config instances of an aliased include, whose field
  // accesses must follow the hoisted local name (#5278).
  recvRenames: Map[String, String]
  configRecvs: Map[String, Bool]
}

func substExprOpt(ctx: in SubstCtx, e: in Option[Expr]): Option[Expr] {
  match e {
    case Some(x) -> Some(value = substExpr(ctx, x))
    case None -> None
  }
}

func substExprList(ctx: in SubstCtx, xs: in List[Expr]): List[Expr] {
  val ys: List[Expr] = newList()
  var i = 0
  while i < xs.count {
    ys.add(substExpr(ctx, xs[i]))
    i = i + 1
  }
  ys
}

func substExprOrBlock(ctx: in SubstCtx, eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(expr) -> EOBExpr(expr = substExpr(ctx, expr))
    case EOBBlock(block) -> EOBBlock(block = substBlock(ctx, block))
  }
}

func substBlock(ctx: in SubstCtx, b: in Block): Block {
  val ss: List[Statement] = newList()
  var i = 0
  while i < b.statements.count {
    ss.add(substStmt(ctx, b.statements[i]))
    i = i + 1
  }
  Block(statements = ss, span = b.span)
}

func substBlockOpt(ctx: in SubstCtx, b: in Option[Block]): Option[Block] {
  match b {
    case Some(x) -> Some(value = substBlock(ctx, x))
    case None -> None
  }
}

func substStmt(ctx: in SubstCtx, s: in Statement): Statement {
  val kind = match s.kind {
    case SLocal(binding) -> {
      val b2 = match binding {
        case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = substExpr(ctx, init))
        case LBVar(name, ty, init) -> LBVar(name = name, ty = ty, init = substExprOpt(ctx, init))
        case LBLet(name, ty, init) -> LBLet(name = name, ty = ty, init = substExpr(ctx, init))
      }
      SLocal(binding = b2)
    }
    case SAssign(target, op, value) -> SAssign(target = substExpr(ctx, target), op = op, value = substExpr(ctx, value))
    case SReturn(value) -> SReturn(value = substExprOpt(ctx, value))
    case SThrow(expr) -> SThrow(expr = substExpr(ctx, expr))
    case STry(body, catches, finally_) -> {
      val cs: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        cs.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = substBlock(ctx, c.body), span = c.span))
        i = i + 1
      }
      STry(body = substBlock(ctx, body), catches = cs, finally_ = substBlockOpt(ctx, finally_))
    }
    case SDefer(body) -> SDefer(body = substBlock(ctx, body))
    case SScope(binding, body) -> SScope(binding = binding, body = substBlock(ctx, body))
    case SFor(label, pat, iter, body) -> SFor(label = label, pat = pat, iter = substExpr(ctx, iter), body = substBlock(ctx, body))
    case SWhile(label, cond, body) -> SWhile(label = label, cond = substExpr(ctx, cond), body = substBlock(ctx, body))
    case SLoop(label, body) -> SLoop(label = label, body = substBlock(ctx, body))
    case SInvariant(expr) -> SInvariant(expr = substExpr(ctx, expr))
    case SExpr(expr) -> SExpr(expr = substExpr(ctx, expr))
    case SRule(lhs, rhs) -> SRule(lhs = substExpr(ctx, lhs), rhs = substExpr(ctx, rhs))
    case _ -> s.kind
  }
  Statement(kind = kind, span = s.span)
}

func substExpr(ctx: in SubstCtx, e: in Expr): Expr {
  val kind = match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(ctx.renames, path.segments[0]) {
          case Some(repl) -> return repl
          case None -> EPath(path = path)
        }
      } else {
        EPath(path = path)
      }
    }
    case EMember(receiver, memberName) -> {
      val recvSingle = match receiver.kind {
        case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
        case _ -> ""
      }
      if recvSingle.length > 0 {
        val key = recvSingle + "/" + memberName
        match mapGet(ctx.memberRewrites, key) {
          case Some(newName) -> {
            val segs: List[String] = newList()
            segs.add(newName)
            return Expr(kind = EPath(path = ModulePath(segments = segs, span = e.span)), span = e.span)
          }
          case None -> {
            match mapGet(ctx.recvRenames, recvSingle) {
              case Some(newRecv) -> {
                val rsegs: List[String] = newList()
                rsegs.add(newRecv)
                val recv2 = Expr(kind = EPath(path = ModulePath(segments = rsegs, span = receiver.span)), span = receiver.span)
                return Expr(kind = EMember(receiver = recv2, memberName = memberName), span = e.span)
              }
              case None -> {
              }
            }
            if ctx.configRecvs.containsKey(recvSingle) {
              // Ordinary config-static access — leave the receiver alone.
              return e
            }
            EMember(receiver = substExpr(ctx, receiver), memberName = memberName)
          }
        }
      } else {
        EMember(receiver = substExpr(ctx, receiver), memberName = memberName)
      }
    }
    case ECall(fn, args) -> {
      val as2: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(expr) -> as2.add(CAPositional(expr = substExpr(ctx, expr)))
          case CANamed(name, value, span) -> as2.add(CANamed(name = name, value = substExpr(ctx, value), span = span))
        }
        i = i + 1
      }
      ECall(fn = substExpr(ctx, fn), args = as2)
    }
    case EParen(inner) -> EParen(inner = substExpr(ctx, inner))
    case ETuple(exprs) -> ETuple(exprs = substExprList(ctx, exprs))
    case EList(exprs) -> EList(exprs = substExprList(ctx, exprs))
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val eb = match elseBranch { case Some(x) -> Some(value = substExprOrBlock(ctx, x)); case None -> None }
      EIf(cond = substExpr(ctx, cond), thenBranch = substExprOrBlock(ctx, thenBranch), elseBranch = eb, thenForm = thenForm)
    }
    case EMatch(scrutinee, arms) -> {
      val as2: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val a = arms[i]
        as2.add(
          MatchArm(
            pattern = a.pattern,
            guard = substExprOpt(ctx, a.guard),
            body = substExprOrBlock(ctx, a.body),
            span = a.span
          )
        )
        i = i + 1
      }
      EMatch(scrutinee = substExpr(ctx, scrutinee), arms = as2)
    }
    case EAwait(inner) -> EAwait(inner = substExpr(ctx, inner))
    case EYield(inner) -> EYield(inner = substExpr(ctx, inner))
    case ESpawn(inner) -> ESpawn(inner = substExpr(ctx, inner))
    case ETry(inner) -> ETry(inner = substExpr(ctx, inner))
    case EOld(inner) -> EOld(inner = substExpr(ctx, inner))
    case ELambda(lambdaParams, body) -> ELambda(lambdaParams = lambdaParams, body = substBlock(ctx, body))
    case ETypeApp(fn, args) -> ETypeApp(fn = substExpr(ctx, fn), args = args)
    case EIndex(receiver, indices) -> EIndex(receiver = substExpr(ctx, receiver), indices = substExprList(ctx, indices))
    case EPropagate(inner) -> EPropagate(inner = substExpr(ctx, inner))
    case EPrefix(op, operand) -> EPrefix(op = op, operand = substExpr(ctx, operand))
    case EBinop(op, lhs, rhs) -> EBinop(op = op, lhs = substExpr(ctx, lhs), rhs = substExpr(ctx, rhs))
    case ERange(bound) -> {
      val b2 = match bound {
        case RBClosed(lo, hi) -> RBClosed(lo = substExpr(ctx, lo), hi = substExpr(ctx, hi))
        case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = substExpr(ctx, lo), hi = substExpr(ctx, hi))
        case RBLowerOpen(hi) -> RBLowerOpen(hi = substExpr(ctx, hi))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = substExpr(ctx, lo))
      }
      ERange(bound = b2)
    }
    case EAssign(target, op, value) -> EAssign(target = substExpr(ctx, target), op = op, value = substExpr(ctx, value))
    case EBlock(block) -> EBlock(block = substBlock(ctx, block))
    case EUnsafe(block) -> EUnsafe(block = substBlock(ctx, block))
    case EInterpolated(segments) -> {
      val ss: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(text, span) -> ss.add(ISText(text = text, span = span))
          case ISExpr(expr) -> ss.add(ISExpr(expr = substExpr(ctx, expr)))
        }
        i = i + 1
      }
      EInterpolated(segments = ss)
    }
    case _ -> e.kind
  }
  Expr(kind = kind, span = e.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Config templates.
// ─────────────────────────────────────────────────────────────────────────────
/// One config-template instantiation visible to a file's wires: the local
/// (config-block) name plus the template's record-constructor name and
/// ordered field list, for the value-position record-construction rewrite.
record ConfigInstance {
  localName: String
  ctorName: String
  fields: List[ConfigField]
}

/// Types legal for a config field (docs/25 §3, v1 self-hosted subset —
/// mirrors `checkConfigBlock`'s G0009 set).
func configTypeAllowedWE(t: in TypeExpr): Bool {
  val n = match t.kind { case TRef(path) -> lastSegmentWE(path); case _ -> "" }
  n == "Bool" or n == "Int" or n == "Long" or n == "Float" or n == "Double" or n == "String"
}

/// Validate a `pub config` template declaration's fields (the analogue of
/// the checker's G0009 for a template that never becomes a config block
/// itself).  Emits W0014 for a disallowed field type.
func validateConfigTemplateDecl(diags: in List[Diagnostic], decl: in ConfigDecl): Unit {
  var i = 0
  while i < decl.fields.count {
    val f = decl.fields[i]
    if not configTypeAllowedWE(f.ty) {
      diags.add(
        errorDiagnostic(
          "W0014",
          "config template '" + decl.name + "' field '" + f.name +
            "' has a type not allowed in a config template; allowed types: Bool, Int, Long, Float, Double, String",
          f.ty.span
        )
      )
    }
    i = i + 1
  }
}

/// Build the `pub record` twin of a config template — the template's field
/// shape as a nominal type, constructible in value position.
func configTemplateRecordItem(templateItem: in Item, decl: in ConfigDecl): Item {
  val members: List[RecordMember] = newList()
  val emptyDocs: List[DocComment] = newList()
  val emptyAnns: List[Annotation] = newList()
  var i = 0
  while i < decl.fields.count {
    val f = decl.fields[i]
    members.add(
      RMField(
        field = FieldDecl(
          docComments = emptyDocs,
          annotations = emptyAnns,
          visibility = None,
          isMutable = false,
          name = f.name,
          ty = f.ty,
          dflt = None,
          span = f.span
        )
      )
    )
    i = i + 1
  }
  val rec = RecordDecl(name = decl.name, generics = None, whereClause = None, members = members, span = decl.span)
  Item(
    docComments = templateItem.docComments,
    annotations = templateItem.annotations,
    visibility = templateItem.visibility,
    kind = IRecord(decl = rec),
    span = templateItem.span
  )
}

/// Merge a config-template instantiation over its template: template fields
/// in template order; an overridden field keeps the template's declared
/// type and takes the instantiation's default.  Emits W0011 (unknown
/// field) and W0012 (type mismatch) for bad overrides.
func materializeConfigInstance(
  diags: in List[Diagnostic],
  localName: in String,
  tmpl: in ConfigDecl,
  overrides: in List[ConfigField],
  span: in Span,
): ConfigDecl {
  // Validate overrides against the template.
  var oi = 0
  while oi < overrides.count {
    val ov = overrides[oi]
    var found = false
    var ti = 0
    while ti < tmpl.fields.count {
      if tmpl.fields[ti].name == ov.name {
        found = true
        if typeToStrWE(tmpl.fields[ti].ty) != typeToStrWE(ov.ty) {
          diags.add(
            errorDiagnostic(
              "W0012",
              "config override '" + localName + "." + ov.name + "' declares type " + typeToStrWE(ov.ty) + " but template '" +
                tmpl.name +
                "' declares " +
                typeToStrWE(tmpl.fields[ti].ty),
              ov.span
            )
          )
        }
      }
      ti = ti + 1
    }
    if not found {
      diags.add(
        errorDiagnostic(
          "W0011",
          "config override '" + localName + "." + ov.name + "' does not exist on template '" + tmpl.name + "'",
          ov.span
        )
      )
    }
    oi = oi + 1
  }
  // Merge: template order, override defaults win.
  val merged: List[ConfigField] = newList()
  var ti2 = 0
  while ti2 < tmpl.fields.count {
    val tf = tmpl.fields[ti2]
    var dflt = tf.default
    var oj = 0
    while oj < overrides.count {
      if overrides[oj].name == tf.name {
        dflt = overrides[oj].default
      }
      oj = oj + 1
    }
    merged.add(
      ConfigField(
        docComments = tf.docComments,
        annotations = tf.annotations,
        name = tf.name,
        ty = tf.ty,
        default = dflt,
        span = tf.span
      )
    )
    ti2 = ti2 + 1
  }
  ConfigDecl(name = localName, from = None, fields = merged, span = span)
}

/// The record-construction expression a value-position use of a config
/// instantiation rewrites to: `Ctor(f1 = Local.f1, f2 = Local.f2, …)`.
func configInstanceCtorExpr(inst: in ConfigInstance, span: in Span): Expr {
  val args: List[CallArg] = newList()
  var i = 0
  while i < inst.fields.count {
    val f = inst.fields[i]
    val recvSegs: List[String] = newList()
    recvSegs.add(inst.localName)
    val recv = Expr(kind = EPath(path = ModulePath(segments = recvSegs, span = span)), span = span)
    val fieldRead = Expr(kind = EMember(receiver = recv, memberName = f.name), span = span)
    args.add(CANamed(name = f.name, value = fieldRead, span = span))
    i = i + 1
  }
  val ctorSegs: List[String] = newList()
  ctorSegs.add(inst.ctorName)
  val ctorHead = Expr(kind = EPath(path = ModulePath(segments = ctorSegs, span = span)), span = span)
  Expr(kind = ECall(fn = ctorHead, args = args), span = span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Wire expansion working state.
// ─────────────────────────────────────────────────────────────────────────────
/// One contributes entry in the (partially) expanded wire, tagged with the
/// scope that declared it: `originId` 0 is the consumer wire's own body;
/// each processed include gets a fresh positive id.
record ContribEntry {
  collection: String
  iface: TypeExpr
  name: String
  init: Expr
  ordering: List[WireOrdering]
  isSealed: Bool
  originId: Int
  span: Span
}

/// A plain (non-contributes) member of the expanded wire.
record PlainMember {
  member: WireMember
  name: String
}

/// An unmapped `@provided` input of an included template, left as a bare
/// name reference: it must resolve to SOME binding in the finished wire
/// scope, else W0017 fires at finalisation.
record PendingProvided {
  name: String
  templateFqn: String
  span: Span
}

/// Mutable expansion state for one consumer wire.
record WireScope {
  plainMembers: List[PlainMember]
  contribs: List[ContribEntry]
  exposes: List[WireMember]
  hoistedConfigs: List[Item]
  configInstances: List[ConfigInstance]
  memberRewrites: Map[String, String]
  names: Map[String, Bool]
  pendingProvided: List[PendingProvided]
  diags: List[Diagnostic]
}

func scopeAddName(sc: in WireScope, name: in String, span: in Span): Unit {
  if sc.names.containsKey(name) {
    sc.diags.add(
      errorDiagnostic(
        "W0024",
        "name '" + name +
          "' collides with an existing binding in this wire; alias the include ('include … as Alias') or rename the local binding",
        span
      )
    )
  } else {
    sc.names.add(name, true)
  }
}

func scopeAddPlain(sc: in WireScope, m: in WireMember, name: in String, span: in Span): Unit {
  if name.length > 0 {
    scopeAddName(sc, name, span)
  }
  sc.plainMembers.add(PlainMember(member = m, name = name))
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Include expansion.
// ─────────────────────────────────────────────────────────────────────────────
/// A bare single-name path expression, used as a rename target.
func bareNameExpr(name: in String, span: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  Expr(kind = EPath(path = ModulePath(segments = segs, span = span)), span = span)
}

func renameTo(renames: in Map[String, Expr], n: in String, newName: in String, span: in Span): Unit {
  // First-wins: a name can be classified once (e.g. an exposed contributes
  // entry hits both the exposed and the contributes mapping loops).
  if not renames.containsKey(n) {
    renames.add(n, bareNameExpr(newName, span))
  }
}

/// Declaration index of a named entry in a contributes group, or -1.
func indexOfContribEntry(entries: in List[ContribEntry], name: in String): Int {
  var k = 0
  while k < entries.count {
    if entries[k].name == name {
      return k
    }
    k = k + 1
  }
  0 - 1
}

/// The `expose`d member names of a wire template, in declaration order.
func templateExposedNames(decl: in WireDecl): List[String] {
  val xs: List[String] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case WMExpose(name, _) -> xs.add(name)
      case _ -> {
      }
    }
    i = i + 1
  }
  xs
}

func templateOverridableNames(decl: in WireDecl): List[String] {
  val xs: List[String] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case WMOverridable(names, _) -> {
        var j = 0
        while j < names.count {
          xs.add(names[j])
          j = j + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  xs
}

/// Expand one `include Pkg.Module [as Alias] { adjustments }` into the
/// consumer wire's scope.  `inclOrdinal` numbers this include within the
/// consumer wire (for `__incl<N>_` internal names); `includeStack` carries
/// the FQNs currently being expanded, for cycle detection (W0016).
func expandInclude(
  sc: in WireScope,
  wires: in Map[String, CollectedWireTemplate],
  configs: in Map[String, CollectedConfigTemplate],
  pkgName: in String,
  path: in ModulePath,
  aliasOpt: in Option[String],
  adjustments: in List[IncludeAdjust],
  span: in Span,
  inclOrdinal: in Int,
  originId: in Int,
  includeStack: in List[String],
  parentExposedTargets: in Map[String, String],
): Unit {
  val fqnWritten = dottedPathWE(path)
  val tmplOpt = lookupWireTemplate(wires, fqnWritten, pkgName)
  match tmplOpt {
    case Some(_) -> {
    }
    case None -> {
      sc.diags.add(
        errorDiagnostic(
          "W0015",
          "include references unknown wire template '" + fqnWritten +
            "'; a template must be a 'pub wire' in an imported package (or this package)",
          span
        )
      )
      return ()
    }
  }
  val emptyParams: List[Param] = newList()
  val emptyMembers: List[WireMember] = newList()
  val tmpl = match tmplOpt {
    case Some(t) -> t
    case None -> CollectedWireTemplate(decl = WireDecl(name = "", params = emptyParams, members = emptyMembers, span = span), pkgName = "")
  }
  val fqn = tmpl.pkgName + "." + tmpl.decl.name
  if listContainsWE(includeStack, fqn) {
    sc.diags.add(
      errorDiagnostic("W0016", "include cycle detected: wire template '" + fqn + "' transitively includes itself", span)
    )
    return ()
  }

  val exposedNames = templateExposedNames(tmpl.decl)
  val overridable = templateOverridableNames(tmpl.decl)
  val prefix = "__incl" + toString(inclOrdinal) + "_"
  val aliasName = match aliasOpt { case Some(a) -> a; case None -> "" }

  // Adjustment tables.
  val providedMap: Map[String, Expr] = newMap()
  val replaceMap: Map[String, Expr] = newMap()
  val removeSet: Map[String, Bool] = newMap()
  val reorderMap: Map[String, List[WireOrdering]] = newMap()
  val cfgOverrideMap: Map[String, List[ConfigFieldOverride]] = newMap()

  // Template surface tables for adjustment validation.
  val providedNames: List[String] = newList()
  val entryNames: List[String] = newList()
  val cfgInstNames: List[String] = newList()
  val contribNames: List[String] = newList()
  val sealedContribs: Map[String, Bool] = newMap()
  var ti = 0
  while ti < tmpl.decl.members.count {
    match tmpl.decl.members[ti] {
      case WMProvided(n, _, _) -> providedNames.add(n)
      case WMSingleton(n, _, _, _) -> entryNames.add(n)
      case WMLocal(n, _, _, _) -> entryNames.add(n)
      case WMBind(iface, _, _) -> entryNames.add(collectionNameOf(iface))
      case WMContributes(_, n, _, _, isSealed, _) -> {
        entryNames.add(n)
        contribNames.add(n)
        if isSealed {
          sealedContribs.add(n, true)
        }
      }
      case WMConfigInst(decl, _) -> cfgInstNames.add(decl.name)
      case _ -> {
      }
    }
    ti = ti + 1
  }

  var ai = 0
  while ai < adjustments.count {
    match adjustments[ai] {
      case IAProvided(n, value, aspan) -> {
        if not listContainsWE(providedNames, n) {
          sc.diags.add(
            errorDiagnostic(
              "W0025",
              "'@provided " + n + ":' does not match any @provided input of wire template '" + fqn + "'",
              aspan
            )
          )
        } else if not providedMap.containsKey(n) {
          providedMap.add(n, value)
        }
      }
      case IAConfigOverride(n, fields, aspan) -> {
        if not listContainsWE(cfgInstNames, n) {
          sc.diags.add(
            errorDiagnostic(
              "W0019",
              "config override target '" + n + "' is not a config instantiation of wire template '" + fqn + "'",
              aspan
            )
          )
        } else if not listContainsWE(overridable, n) {
          sc.diags.add(errorDiagnostic("W0018", "'" + n + "' is not in wire template '" + fqn + "''s overridable list", aspan))
        } else if not cfgOverrideMap.containsKey(n) {
          cfgOverrideMap.add(n, fields)
        }
      }
      case IAReplace(n, value, aspan) -> {
        if not listContainsWE(entryNames, n) {
          sc.diags.add(
            errorDiagnostic("W0019", "replace target '" + n + "' does not exist in wire template '" + fqn + "'", aspan)
          )
        } else if not listContainsWE(overridable, n) {
          sc.diags.add(errorDiagnostic("W0018", "'" + n + "' is not in wire template '" + fqn + "''s overridable list", aspan))
        } else if not replaceMap.containsKey(n) {
          replaceMap.add(n, value)
        }
      }
      case IARemove(n, aspan) -> {
        if not listContainsWE(entryNames, n) {
          sc.diags.add(
            errorDiagnostic("W0019", "remove target '" + n + "' does not exist in wire template '" + fqn + "'", aspan)
          )
        } else if sealedContribs.containsKey(n) {
          sc.diags.add(
            errorDiagnostic(
              "W0023",
              "'" + n + "' belongs to a sealed contributes collection; it cannot be removed from outside the declaring module",
              aspan
            )
          )
        } else if not listContainsWE(overridable, n) {
          sc.diags.add(errorDiagnostic("W0018", "'" + n + "' is not in wire template '" + fqn + "''s overridable list", aspan))
        } else if not removeSet.containsKey(n) {
          removeSet.add(n, true)
        }
      }
      case IAReorder(n, ordering, aspan) -> {
        if not listContainsWE(contribNames, n) {
          sc.diags.add(
            errorDiagnostic(
              "W0019",
              "reorder target '" + n + "' is not a contributes entry of wire template '" + fqn + "'",
              aspan
            )
          )
        } else if sealedContribs.containsKey(n) {
          sc.diags.add(
            errorDiagnostic(
              "W0023",
              "'" + n + "' belongs to a sealed contributes collection; it cannot be reordered from outside the declaring module",
              aspan
            )
          )
        } else if not reorderMap.containsKey(n) {
          reorderMap.add(n, ordering)
        }
      }
    }
    ai = ai + 1
  }

  // Build the rename map for the spliced member initialisers.
  //   - internal (non-surface) names -> "__incl<N>_<name>"
  //   - surface names under an alias -> "__incl_<Alias>_<name>" (exposed)
  //     while contributes entries / collections stay internal
  //   - @provided inputs -> mapping expression (or bare same name)
  val renames: Map[String, Expr] = newMap()
  val configRecvs: Map[String, Bool] = newMap()

  // @provided inputs: explicit mapping wins; otherwise the bare same name
  // must resolve in the includer's scope (validated at wire finalisation).
  var pi = 0
  while pi < providedNames.count {
    val pn = providedNames[pi]
    match mapGet(providedMap, pn) {
      case Some(expr) -> {
        val isSimple = match expr.kind { case EPath(p) -> p.segments.count == 1; case _ -> false }
        if isSimple {
          renames.add(pn, expr)
        } else {
          // Bind the mapping expression once as an internal member and
          // substitute the internal name, so the expression is evaluated
          // once rather than per reference.
          val internalName = prefix + "prov_" + pn
          scopeAddPlain(sc, WMLocal(name = internalName, ty = None, init = expr, span = span), internalName, span)
          renameTo(renames, pn, internalName, span)
        }
      }
      case None -> {
        // Bare passthrough: leave references to `pn` untouched; W0017 is
        // raised at finalisation when the includer has no such binding.
        sc.pendingProvided.add(PendingProvided(name = pn, templateFqn = fqn, span = span))
      }
    }
    pi = pi + 1
  }

  // Surface-name mapping.  A name this template exposes that the PARENT
  // template re-exposes under a target of its own (nested inclusion) takes
  // the parent's target, so `include Outer as Public` reaches a
  // nested-and-re-exposed member via `Public.<name>` correctly.
  val exposedTargets: Map[String, String] = newMap()
  var ei = 0
  while ei < exposedNames.count {
    val en = exposedNames[ei]
    match mapGet(parentExposedTargets, en) {
      case Some(pt) -> {
        exposedTargets.add(en, pt)
        if pt != en {
          renameTo(renames, en, pt, span)
        }
      }
      case None -> {
        if aliasName.length > 0 {
          val mangled = "__incl_" + aliasName + "_" + en
          exposedTargets.add(en, mangled)
          renameTo(renames, en, mangled, span)
          val mrKey = aliasName + "/" + en
          if not sc.memberRewrites.containsKey(mrKey) {
            sc.memberRewrites.add(mrKey, mangled)
          }
        } else {
          exposedTargets.add(en, en)
        }
      }
    }
    ei = ei + 1
  }

  // Config instances: hoist under the local (or alias-prefixed) name.
  // For an aliased include, spliced field accesses (`Files.root`) must
  // follow the hoisted local name (`Alias_Files.root`) — receiver-only
  // renames handle that (#5278); value-position uses go through the
  // ordinary rename map.
  val localCfgNames: Map[String, String] = newMap()
  val recvRenames: Map[String, String] = newMap()
  var ci = 0
  while ci < cfgInstNames.count {
    val cn = cfgInstNames[ci]
    val localCfg = if aliasName.length > 0 { aliasName + "_" + cn } else { cn }
    if localCfgNames.containsKey(cn) {
      ci = ci + 1
      continue
    }
    localCfgNames.add(cn, localCfg)
    if localCfg != cn {
      renameTo(renames, cn, localCfg, span)
      recvRenames.add(cn, localCfg)
    }
    if not configRecvs.containsKey(localCfg) {
      configRecvs.add(localCfg, true)
    }
    ci = ci + 1
  }

  // Contributes entries: bare for an unaliased include (their names are
  // part of the collection's public surface — consumer ordering clauses
  // reference them); internal for an aliased include (aliasing isolates
  // the instance, including its collections).
  val contribTargets: Map[String, String] = newMap()
  var cti = 0
  while cti < contribNames.count {
    val cn = contribNames[cti]
    match mapGet(exposedTargets, cn) {
      case Some(et) -> {
        // The template exposes this entry: the exposed mapping (set above,
        // including any alias mangling) is authoritative — the spliced
        // entry must carry the same name `Alias.<cn>` resolves to.
        contribTargets.add(cn, et)
      }
      case None -> {
        if aliasName.length > 0 {
          val mangled = prefix + cn
          contribTargets.add(cn, mangled)
          renameTo(renames, cn, mangled, span)
        } else {
          contribTargets.add(cn, cn)
        }
      }
    }
    cti = cti + 1
  }

  // Internal names: everything else.
  var ii = 0
  while ii < tmpl.decl.members.count {
    match tmpl.decl.members[ii] {
      case WMSingleton(n, _, _, _) -> {
        if not listContainsWE(exposedNames, n) and not listContainsWE(contribNames, n) {
          renameTo(renames, n, prefix + n, span)
        }
      }
      case WMLocal(n, _, _, _) -> {
        if not listContainsWE(exposedNames, n) and not listContainsWE(contribNames, n) {
          renameTo(renames, n, prefix + n, span)
        }
      }
      case WMBind(iface, _, _) -> {
        val n = collectionNameOf(iface)
        if not listContainsWE(exposedNames, n) {
          renameTo(renames, n, prefix + n, span)
        }
      }
      case _ -> {
      }
    }
    ii = ii + 1
  }

  // Collection names: an aliased include's collections are isolated under
  // internal names, so its internal references to the bare collection name
  // must be renamed too.
  if aliasName.length > 0 {
    val seenColls: Map[String, Bool] = newMap()
    var cli = 0
    while cli < tmpl.decl.members.count {
      match tmpl.decl.members[cli] {
        case WMContributes(iface, _, _, _, _, _) -> {
          val coll = collectionNameOf(iface)
          if not seenColls.containsKey(coll) {
            seenColls.add(coll, true)
            renameTo(renames, coll, prefix + coll, span)
          }
        }
        case _ -> {
        }
      }
      cli = cli + 1
    }
  }

  val noMemberRewrites: Map[String, String] = newMap()
  val subst = SubstCtx(
    renames = renames,
    memberRewrites = noMemberRewrites,
    recvRenames = recvRenames,
    configRecvs = configRecvs
  )

  // Splice members.
  var mi = 0
  while mi < tmpl.decl.members.count {
    match tmpl.decl.members[mi] {
      case WMProvided(_, _, _) -> {
        // Substituted away; never spliced.
      }
      case WMExpose(_, _) -> {
        // Exposure is scope propagation, not a spliced member: the exposed
        // name is reachable in the includer (bare or via alias) and only
        // exposed from the consumer wire if the consumer exposes it.
      }
      case WMOverridable(_, _) -> {
        // Consumed at adjustment validation; never spliced.
      }
      case WMSingleton(n, ty, init, mspan) -> {
        if not removeSet.containsKey(n) {
          val effInit = match mapGet(replaceMap, n) {
            case Some(replacement) -> replacement
            case None -> substExpr(subst, init)
          }
          val target = match mapGet(exposedTargets, n) { case Some(t) -> t; case None -> prefix + n }
          scopeAddPlain(sc, WMSingleton(name = target, ty = ty, init = effInit, span = mspan), target, mspan)
        }
      }
      case WMLocal(n, ty, init, mspan) -> {
        if not removeSet.containsKey(n) {
          val effInit = match mapGet(replaceMap, n) {
            case Some(replacement) -> replacement
            case None -> substExpr(subst, init)
          }
          val target = match mapGet(exposedTargets, n) { case Some(t) -> t; case None -> prefix + n }
          scopeAddPlain(sc, WMLocal(name = target, ty = ty, init = effInit, span = mspan), target, mspan)
        }
      }
      case WMBind(iface, provider, mspan) -> {
        val n = collectionNameOf(iface)
        if not removeSet.containsKey(n) {
          val effInit = match mapGet(replaceMap, n) {
            case Some(replacement) -> replacement
            case None -> substExpr(subst, provider)
          }
          val target = match mapGet(exposedTargets, n) { case Some(t) -> t; case None -> prefix + n }
          // A bind is semantically a local named after its interface; the
          // spliced form keeps the interface as the declared type.
          scopeAddPlain(sc, WMLocal(name = target, ty = Some(value = iface), init = effInit, span = mspan), target, mspan)
        }
      }
      case WMScoped(scopeName, n, ty, init, mspan) -> {
        // Pass through under an internal name; codegen still rejects scoped
        // members (#2972) — inclusion does not change that contract.
        scopeAddPlain(
          sc,
          WMScoped(scopeName = scopeName, name = prefix + n, ty = ty, init = substExpr(subst, init), span = mspan),
          prefix + n,
          mspan
        )
      }
      case WMContributes(iface, n, init, ordering, isSealed, mspan) -> {
        if not removeSet.containsKey(n) {
          val effInit = match mapGet(replaceMap, n) {
            case Some(replacement) -> replacement
            case None -> substExpr(subst, init)
          }
          val target = match mapGet(contribTargets, n) { case Some(t) -> t; case None -> n }
          val coll0 = collectionNameOf(iface)
          val coll = if aliasName.length > 0 { prefix + coll0 } else { coll0 }
          // Ordering clauses reference sibling entry names — remap them the
          // same way the entries themselves were.
          val ord2: List[WireOrdering] = newList()
          var oi = 0
          while oi < ordering.count {
            match ordering[oi] {
              case WOWraps(on, osp) -> {
                val tn = match mapGet(contribTargets, on) { case Some(t) -> t; case None -> on }
                ord2.add(WOWraps(name = tn, span = osp))
              }
              case WOInside(on, osp) -> {
                val tn = match mapGet(contribTargets, on) { case Some(t) -> t; case None -> on }
                ord2.add(WOInside(name = tn, span = osp))
              }
            }
            oi = oi + 1
          }
          match mapGet(reorderMap, n) {
            case Some(extra) -> {
              var xi = 0
              while xi < extra.count {
                ord2.add(extra[xi])
                xi = xi + 1
              }
            }
            case None -> {
            }
          }
          if aliasName.length == 0 {
            scopeAddName(sc, target, mspan)
          }
          sc.contribs.add(
            ContribEntry(
              collection = coll,
              iface = iface,
              name = target,
              init = effInit,
              ordering = ord2,
              isSealed = isSealed,
              originId = originId,
              span = mspan
            )
          )
        }
      }
      case WMConfigInst(decl, mspan) -> {
        val localCfg = match mapGet(localCfgNames, decl.name) { case Some(n) -> n; case None -> decl.name }
        val noOverrides: List[ConfigFieldOverride] = newList()
        val bodyOverrides = match mapGet(cfgOverrideMap, decl.name) { case Some(fields) -> fields; case None -> noOverrides }
        hoistConfigInstance(sc, configs, tmpl.pkgName, localCfg, decl, bodyOverrides, mspan)
      }
      case WMInclude(ipath, ialias, iadjs, _, ispan) -> {
        // Nested inclusion: expand within the template's own package scope.
        val stack2: List[String] = newList()
        var si = 0
        while si < includeStack.count {
          stack2.add(includeStack[si])
          si = si + 1
        }
        stack2.add(fqn)
        expandInclude(
          sc,
          wires,
          configs,
          tmpl.pkgName,
          ipath,
          ialias,
          iadjs,
          ispan,
          inclOrdinal * 100 + mi + 1,
          originId * 100 + mi + 1,
          stack2,
          exposedTargets
        )
      }
    }
    mi = mi + 1
  }
}

/// Hoist a wire-body config instantiation to module scope: resolve its
/// template, apply the declaration-site overrides plus any include-body
/// overrides, and register the local instance for the value-position
/// record-construction rewrite.
func hoistConfigInstance(
  sc: in WireScope,
  configs: in Map[String, CollectedConfigTemplate],
  pkgName: in String,
  localName: in String,
  decl: in ConfigDecl,
  extraOverrides: in List[ConfigFieldOverride],
  span: in Span,
): Unit {
  val emptySegs: List[String] = newList()
  val fromPath = match decl.from { case Some(p) -> p; case None -> ModulePath(segments = emptySegs, span = span) }
  if fromPath.segments.count == 0 {
    // No `from` clause: the parser already rejected this form (P0343).
    return ()
  }
  val tmplOpt = lookupConfigTemplate(configs, dottedPathWE(fromPath), pkgName)
  match tmplOpt {
    case Some(_) -> {
    }
    case None -> {
      sc.diags.add(
        errorDiagnostic(
          "W0010",
          "config instantiation '" + localName + "' references unknown config template '" + dottedPathWE(fromPath) + "'",
          span
        )
      )
      return ()
    }
  }
  val emptyFields: List[ConfigField] = newList()
  val tmpl = match tmplOpt {
    case Some(t) -> t
    case None -> CollectedConfigTemplate(decl = ConfigDecl(name = "", from = None, fields = emptyFields, span = span), pkgName = "")
  }
  // Declaration-site overrides first, include-body overrides on top.
  val overrides: List[ConfigField] = newList()
  var i = 0
  while i < decl.fields.count {
    overrides.add(decl.fields[i])
    i = i + 1
  }
  var xo = 0
  while xo < extraOverrides.count {
    val ov = extraOverrides[xo]
    // Include-body overrides are untyped `field = value`; the template
    // supplies the declared type (W0011 fires below when the name is
    // unknown to the template).
    var ty: Option[TypeExpr] = None
    var tf = 0
    while tf < tmpl.decl.fields.count {
      if tmpl.decl.fields[tf].name == ov.name {
        ty = Some(value = tmpl.decl.fields[tf].ty)
      }
      tf = tf + 1
    }
    val emptyDocs: List[DocComment] = newList()
    val emptyAnns: List[Annotation] = newList()
    match ty {
      case Some(t) -> {
        // An include-body override for a field wins over any
        // declaration-site override for the same field: overwrite it in
        // place when present, else append.
        val newField = ConfigField(
          docComments = emptyDocs,
          annotations = emptyAnns,
          name = ov.name,
          ty = t,
          default = Some(value = ov.value),
          span = ov.span
        )
        var replacedAt = 0 - 1
        var ki = 0
        while ki < overrides.count {
          if overrides[ki].name == ov.name {
            replacedAt = ki
          }
          ki = ki + 1
        }
        if replacedAt >= 0 {
          overrides[replacedAt] = newField
        } else {
          overrides.add(newField)
        }
      }
      case None -> {
        sc.diags.add(
          errorDiagnostic(
            "W0011",
            "config override '" + localName + "." + ov.name + "' does not exist on template '" + tmpl.decl.name + "'",
            ov.span
          )
        )
      }
    }
    xo = xo + 1
  }
  // The instance's local name lives in the wire's bare namespace (it is
  // referenceable in value position and as a config-static qualifier), so
  // a collision with any existing binding is W0024 like any other splice
  // (#5279).
  scopeAddName(sc, localName, span)
  val materialized = materializeConfigInstance(sc.diags, localName, tmpl.decl, overrides, span)
  val emptyDocs2: List[DocComment] = newList()
  val emptyAnns2: List[Annotation] = newList()
  sc.hoistedConfigs.add(
    Item(
      docComments = emptyDocs2,
      annotations = emptyAnns2,
      visibility = None,
      kind = IConfig(decl = materialized),
      span = span
    )
  )
  sc.configInstances.add(ConfigInstance(localName = localName, ctorName = tmpl.decl.name, fields = materialized.fields))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Contributes resolution.
// ─────────────────────────────────────────────────────────────────────────────
/// Order one collection's entries: declaration order adjusted by
/// `wraps:`/`inside:` constraints (`e wraps x` → e before x; `e inside x`
/// → e after x), outermost-first.  Kahn's algorithm with the smallest
/// declaration index as the tiebreak, so the result is deterministic and
/// stable when no constraints apply.  A constraint cycle is W0021; a
/// reference to an unknown entry is W0022.
func orderContribEntries(diags: in List[Diagnostic], entries: in List[ContribEntry]): List[Int] {
  val n = entries.count
  // edges[i] holds the indices that must come AFTER entry i.
  val edges: List[List[Int]] = newList()
  val inDegree: List[Int] = newList()
  var i = 0
  while i < n {
    val e: List[Int] = newList()
    edges.add(e)
    inDegree.add(0)
    i = i + 1
  }

  var ei = 0
  while ei < n {
    val ce = entries[ei]
    var oi = 0
    while oi < ce.ordering.count {
      match ce.ordering[oi] {
        case WOWraps(on, osp) -> {
          val target = indexOfContribEntry(entries, on)
          if target < 0 {
            diags.add(
              errorDiagnostic(
                "W0022",
                "'wraps: " + on + "' references an entry that is not part of collection '" + ce.collection + "'",
                osp
              )
            )
          } else {
            edges[ei].add(target)
            inDegree[target] = inDegree[target] + 1
          }
        }
        case WOInside(on, osp) -> {
          val target = indexOfContribEntry(entries, on)
          if target < 0 {
            diags.add(
              errorDiagnostic(
                "W0022",
                "'inside: " + on + "' references an entry that is not part of collection '" + ce.collection + "'",
                osp
              )
            )
          } else {
            edges[target].add(ei)
            inDegree[ei] = inDegree[ei] + 1
          }
        }
      }
      oi = oi + 1
    }
    ei = ei + 1
  }

  val order: List[Int] = newList()
  val done: List[Bool] = newList()
  var di = 0
  while di < n {
    done.add(false)
    di = di + 1
  }
  var produced = 0
  var stuck = false
  while produced < n and not stuck {
    var pick = 0 - 1
    var k = 0
    while k < n {
      if not done[k] and inDegree[k] == 0 and pick < 0 {
        pick = k
      }
      k = k + 1
    }
    if pick < 0 {
      stuck = true
    } else {
      done[pick] = true
      order.add(pick)
      produced = produced + 1
      var e2 = 0
      while e2 < edges[pick].count {
        val t = edges[pick][e2]
        inDegree[t] = inDegree[t] - 1
        e2 = e2 + 1
      }
    }
  }
  if stuck {
    diags.add(
      errorDiagnostic(
        "W0021",
        "ordering constraints on collection '" + entries[0].collection + "' form a cycle",
        entries[0].span
      )
    )
    // Fall back to declaration order so expansion can continue.
    val fallback: List[Int] = newList()
    var f = 0
    while f < n {
      fallback.add(f)
      f = f + 1
    }
    return fallback
  }
  order
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Per-wire expansion driver.
// ─────────────────────────────────────────────────────────────────────────────
record ExpandedWire {
  decl: WireDecl
  hoistedConfigs: List[Item]
  diags: List[Diagnostic]
}

func expandWireDecl(
  decl: in WireDecl,
  pkgName: in String,
  wires: in Map[String, CollectedWireTemplate],
  configs: in Map[String, CollectedConfigTemplate],
  moduleConfigInstances: in List[ConfigInstance],
): ExpandedWire {
  val diags: List[Diagnostic] = newList()
  val sc = WireScope(
    plainMembers = newList(),
    contribs = newList(),
    exposes = newList(),
    hoistedConfigs = newList(),
    configInstances = newList(),
    memberRewrites = newMap(),
    names = newMap(),
    pendingProvided = newList(),
    diags = diags
  )
  // Module-level config instantiations are in scope for this wire's
  // value-position rewrite.
  var mci = 0
  while mci < moduleConfigInstances.count {
    sc.configInstances.add(moduleConfigInstances[mci])
    mci = mci + 1
  }

  var inclOrdinal = 0
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case WMInclude(path, aliasOpt, adjustments, _, mspan) -> {
        inclOrdinal = inclOrdinal + 1
        val stack: List[String] = newList()
        stack.add(pkgName + "." + decl.name)
        val noParentTargets: Map[String, String] = newMap()
        expandInclude(
          sc,
          wires,
          configs,
          pkgName,
          path,
          aliasOpt,
          adjustments,
          mspan,
          inclOrdinal,
          inclOrdinal,
          stack,
          noParentTargets
        )
      }
      case WMContributes(iface, n, init, ordering, isSealed, mspan) -> {
        scopeAddName(sc, n, mspan)
        sc.contribs.add(
          ContribEntry(
            collection = collectionNameOf(iface),
            iface = iface,
            name = n,
            init = init,
            ordering = ordering,
            isSealed = isSealed,
            originId = 0,
            span = mspan
          )
        )
      }
      case WMConfigInst(cdecl, mspan) -> {
        val noOverrides: List[ConfigFieldOverride] = newList()
        hoistConfigInstance(sc, configs, pkgName, cdecl.name, cdecl, noOverrides, mspan)
      }
      case WMOverridable(_, mspan) -> {
        diags.add(
          warningDiagnostic(
            "W0026",
            "'overridable' has no effect in a non-template wire; it gates include-site adjustments of a 'pub wire' template",
            mspan
          )
        )
      }
      case WMExpose(n, mspan) -> sc.exposes.add(WMExpose(name = n, span = mspan))
      case WMProvided(n, ty, mspan) -> scopeAddPlain(sc, WMProvided(name = n, ty = ty, span = mspan), n, mspan)
      case WMSingleton(n, ty, init, mspan) -> scopeAddPlain(sc, WMSingleton(name = n, ty = ty, init = init, span = mspan), n, mspan)
      case WMLocal(n, ty, init, mspan) -> scopeAddPlain(sc, WMLocal(name = n, ty = ty, init = init, span = mspan), n, mspan)
      case WMScoped(scopeName, n, ty, init, mspan) -> scopeAddPlain(sc, WMScoped(scopeName = scopeName, name = n, ty = ty, init = init, span = mspan), n, mspan)
      case WMBind(iface, provider, mspan) -> scopeAddPlain(sc, WMBind(iface = iface, provider = provider, span = mspan), collectionNameOf(iface), mspan)
    }
    mi = mi + 1
  }

  // ── Contributes: group, seal-check, order, synthesise lists. ──
  // Collection names must not clash with plain bindings (W0020).
  val collNames: List[String] = newList()
  var ci = 0
  while ci < sc.contribs.count {
    if not listContainsWE(collNames, sc.contribs[ci].collection) {
      collNames.add(sc.contribs[ci].collection)
    }
    ci = ci + 1
  }
  var cni = 0
  while cni < collNames.count {
    val coll = collNames[cni]
    var pmi = 0
    while pmi < sc.plainMembers.count {
      if sc.plainMembers[pmi].name == coll {
        diags.add(
          errorDiagnostic(
            "W0020",
            "'" + coll + "' has both contributes[…] entries and a plain bind/singleton binding; " +
              "a name cannot resolve as both the instance and the collection",
            decl.span
          )
        )
      }
      pmi = pmi + 1
    }
    cni = cni + 1
  }

  // Sealed collections: every entry must share the sealing origin.
  var si = 0
  while si < sc.contribs.count {
    val e = sc.contribs[si]
    if e.isSealed {
      var sj = 0
      while sj < sc.contribs.count {
        val other = sc.contribs[sj]
        if other.collection == e.collection and other.originId != e.originId {
          diags.add(
            errorDiagnostic(
              "W0023",
              "collection '" + e.collection + "' is sealed by its declaring module; entry '" + other.name +
                "' cannot be contributed from outside it",
              other.span
            )
          )
        }
        sj = sj + 1
      }
    }
    si = si + 1
  }

  // The final value-position rewrite for config instances (consumer-scope
  // names) and alias-qualified access to included exposed members.
  val finalRenames: Map[String, Expr] = newMap()
  val finalConfigRecvs: Map[String, Bool] = newMap()
  var fci = 0
  while fci < sc.configInstances.count {
    val inst = sc.configInstances[fci]
    if not finalRenames.containsKey(inst.localName) {
      finalRenames.add(inst.localName, configInstanceCtorExpr(inst, decl.span))
      finalConfigRecvs.add(inst.localName, true)
    }
    fci = fci + 1
  }
  val noRecvRenames: Map[String, String] = newMap()
  val finalSubst = SubstCtx(
    renames = finalRenames,
    memberRewrites = sc.memberRewrites,
    recvRenames = noRecvRenames,
    configRecvs = finalConfigRecvs
  )

  // Assemble the final member list: plain members (with the final rewrite
  // applied), contributes entries as typed locals in declaration order,
  // one synthesised List[T] member per collection, then exposes.
  val outMembers: List[WireMember] = newList()
  var omi = 0
  while omi < sc.plainMembers.count {
    val pm = sc.plainMembers[omi].member
    val rewritten = match pm {
      case WMSingleton(n, ty, init, mspan) -> WMSingleton(name = n, ty = ty, init = substExpr(finalSubst, init), span = mspan)
      case WMLocal(n, ty, init, mspan) -> WMLocal(name = n, ty = ty, init = substExpr(finalSubst, init), span = mspan)
      case WMBind(iface, provider, mspan) -> WMBind(iface = iface, provider = substExpr(finalSubst, provider), span = mspan)
      case WMScoped(scopeName, n, ty, init, mspan) -> WMScoped(scopeName = scopeName, name = n, ty = ty, init = substExpr(finalSubst, init), span = mspan)
      case _ -> pm
    }
    outMembers.add(rewritten)
    omi = omi + 1
  }
  var cei = 0
  while cei < sc.contribs.count {
    val e = sc.contribs[cei]
    outMembers.add(
      WMLocal(name = e.name, ty = Some(value = e.iface), init = substExpr(finalSubst, e.init), span = e.span)
    )
    cei = cei + 1
  }
  // Synthesise one List[T] per collection, in first-appearance order.
  var cli = 0
  while cli < collNames.count {
    val coll = collNames[cli]
    val group: List[ContribEntry] = newList()
    var gi = 0
    while gi < sc.contribs.count {
      if sc.contribs[gi].collection == coll {
        group.add(sc.contribs[gi])
      }
      gi = gi + 1
    }
    val order = orderContribEntries(diags, group)
    val elems: List[Expr] = newList()
    var oi2 = 0
    while oi2 < order.count {
      val ce = group[order[oi2]]
      val segs: List[String] = newList()
      segs.add(ce.name)
      elems.add(Expr(kind = EPath(path = ModulePath(segments = segs, span = ce.span)), span = ce.span))
      oi2 = oi2 + 1
    }
    val ifaceTy = group[0].iface
    val listArgs: List[TypeArg] = newList()
    listArgs.add(TAType(ty = ifaceTy))
    val listSegs: List[String] = newList()
    listSegs.add("List")
    val listTy = TypeExpr(
      kind = TGenericApp(head = ModulePath(segments = listSegs, span = group[0].span), args = listArgs),
      span = group[0].span
    )
    outMembers.add(
      WMLocal(
        name = coll,
        ty = Some(value = listTy),
        init = Expr(kind = EList(exprs = elems), span = group[0].span),
        span = group[0].span
      )
    )
    cli = cli + 1
  }
  var exi = 0
  while exi < sc.exposes.count {
    outMembers.add(sc.exposes[exi])
    exi = exi + 1
  }

  // W0017: an unmapped `@provided` passthrough must resolve to a binding in
  // the finished wire scope (a member, a contributes entry, or a config
  // instantiation) under the same bare name.
  var ppi2 = 0
  while ppi2 < sc.pendingProvided.count {
    val pp = sc.pendingProvided[ppi2]
    var resolves = sc.names.containsKey(pp.name)
    var cfi = 0
    while cfi < sc.configInstances.count {
      if sc.configInstances[cfi].localName == pp.name {
        resolves = true
      }
      cfi = cfi + 1
    }
    if not resolves {
      diags.add(
        errorDiagnostic(
          "W0017",
          "wire template '" + pp.templateFqn + "' input '@provided " + pp.name +
            "' has no mapping and no same-named binding in the including wire; map it with '@provided " +
            pp.name +
            ": <value>' in the include body",
          pp.span
        )
      )
    }
    ppi2 = ppi2 + 1
  }

  ExpandedWire(
    decl = WireDecl(name = decl.name, params = decl.params, members = outMembers, span = decl.span),
    hoistedConfigs = sc.hoistedConfigs,
    diags = diags
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. File-level entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub record WireExpandResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// True when the file contains anything docs/58-shaped: a pub wire or pub
/// config item, a `config … from …` instantiation, or a wire whose members
/// use contributes/include/overridable/config-instantiation.
func fileNeedsExpansion(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    val isPub = match it.visibility { case Some(_) -> true; case None -> false }
    match it.kind {
      case IConfig(decl) -> {
        if isPub {
          return true
        }
        match decl.from {
          case Some(_) -> return true
          case None -> {
          }
        }
      }
      case IWire(decl) -> {
        if isPub {
          return true
        }
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case WMContributes(_, _, _, _, _, _) -> return true
            case WMInclude(_, _, _, _, _) -> return true
            case WMOverridable(_, _) -> return true
            case WMConfigInst(_, _) -> return true
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
  false
}

/// Expand every docs/58 construct in `file` against the templates collected
/// from the whole compilation (see `collectWireTemplates`).  Returns the
/// rewritten file plus expansion diagnostics; a file with no docs/58
/// constructs is returned unchanged.
pub func expandFile(
  file: in SourceFile,
  wires: in Map[String, CollectedWireTemplate],
  configs: in Map[String, CollectedConfigTemplate],
): WireExpandResult {
  val noDiags: List[Diagnostic] = newList()
  if not fileNeedsExpansion(file) {
    return WireExpandResult(file = file, diagnostics = noDiags)
  }

  val pkgName = dottedPathWE(file.packageDecl.path)
  val diags: List[Diagnostic] = newList()
  val outItems: List[Item] = newList()
  val moduleConfigInstances: List[ConfigInstance] = newList()

  // Pass 1 — config templates and module-level instantiations.
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    val isPub = match it.visibility { case Some(_) -> true; case None -> false }
    match it.kind {
      case IConfig(decl) -> {
        match decl.from {
          case Some(fromPath) -> {
            if isPub {
              diags.add(
                errorDiagnostic(
                  "W0013",
                  "a config-template instantiation is package-private; remove 'pub' from 'config " + decl.name + "'",
                  it.span
                )
              )
            }
            val tmplOpt = lookupConfigTemplate(configs, dottedPathWE(fromPath), pkgName)
            match tmplOpt {
              case Some(tmpl) -> {
                val materialized = materializeConfigInstance(diags, decl.name, tmpl.decl, decl.fields, decl.span)
                outItems.add(
                  Item(
                    docComments = it.docComments,
                    annotations = it.annotations,
                    visibility = None,
                    kind = IConfig(decl = materialized),
                    span = it.span
                  )
                )
                moduleConfigInstances.add(
                  ConfigInstance(localName = decl.name, ctorName = tmpl.decl.name, fields = materialized.fields)
                )
              }
              case None -> {
                diags.add(
                  errorDiagnostic(
                    "W0010",
                    "config instantiation '" + decl.name + "' references unknown config template '" + dottedPathWE(fromPath) + "'",
                    decl.span
                  )
                )
                outItems.add(it)
              }
            }
          }
          case None -> {
            if isPub {
              // Template declaration: validate, then replace with the
              // synthesised record twin.
              validateConfigTemplateDecl(diags, decl)
              outItems.add(configTemplateRecordItem(it, decl))
            } else {
              outItems.add(it)
            }
          }
        }
      }
      case _ -> outItems.add(it)
    }
    i = i + 1
  }

  // Pass 2 — wires: drop pub templates, expand plain wires.
  val finalItems: List[Item] = newList()
  var j = 0
  while j < outItems.count {
    val it = outItems[j]
    val isPub = match it.visibility { case Some(_) -> true; case None -> false }
    match it.kind {
      case IWire(decl) -> {
        if isPub {
          // A pub wire is a template: collected before expansion, never
          // bootstrapped as this package's own graph.
        } else {
          val expanded = expandWireDecl(decl, pkgName, wires, configs, moduleConfigInstances)
          var di = 0
          while di < expanded.diags.count {
            diags.add(expanded.diags[di])
            di = di + 1
          }
          finalItems.add(
            Item(
              docComments = it.docComments,
              annotations = it.annotations,
              visibility = it.visibility,
              kind = IWire(decl = expanded.decl),
              span = it.span
            )
          )
          var hi = 0
          while hi < expanded.hoistedConfigs.count {
            finalItems.add(expanded.hoistedConfigs[hi])
            hi = hi + 1
          }
        }
      }
      case _ -> finalItems.add(it)
    }
    j = j + 1
  }

  WireExpandResult(
    file = SourceFile(
      moduleDoc = file.moduleDoc,
      fileAnnotations = file.fileAnnotations,
      packageDecl = file.packageDecl,
      imports = file.imports,
      items = finalItems,
      span = file.span
    ),
    diagnostics = diags
  )
}
