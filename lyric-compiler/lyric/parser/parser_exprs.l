// parser_exprs.l — generic params, where-clauses, type expressions,
// patterns, and the full expression/block/statement grammar.
// Mirrors the corresponding sections of compiler/src/Lyric.Parser/Parser.fs.
package Lyric.Parser

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// AST constructor helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func mkExpr(kind: in ExprKind, span: in Span): Expr {
  Expr(kind = kind, span = span)
}

pub func mkType(kind: in TypeExprKind, span: in Span): TypeExpr {
  TypeExpr(kind = kind, span = span)
}

pub func mkPat(kind: in PatternKind, span: in Span): Pattern {
  Pattern(kind = kind, span = span)
}

pub func mkStmt(kind: in StatementKind, span: in Span): Statement {
  Statement(kind = kind, span = span)
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic parameters.
// ─────────────────────────────────────────────────────────────────────────────

func parseGenericParam(st: inout ParseState): GenericParam {
  val nameTok = peek(st)
  match tryEatIdent(st) {
    case Some(ns) -> {
      if isPunct(peekToken(st), Colon) {
        val _ = advance(st)
        val ty = parseTypeExpr(st)
        GPValue(name = ns.name, constraint = ty, span = joinSpans(ns.span, ty.span))
      } else {
        GPType(name = ns.name, span = ns.span)
      }
    }
    case None -> {
      emitErr(st, "P0090", "expected an identifier in generic parameter list", nameTok.span)
      if not isAtEnd(st) { val _ = advance(st) }
      GPType(name = "<error>", span = nameTok.span)
    }
  }
}

pub func parseGenericParamsOpt(st: inout ParseState): Option[GenericParams] {
  // Two forms: bare-bracket `[T, U]` or legacy `generic[T, U]`.
  val isGenericKw = isKw(peekToken(st), KwGeneric)
  val isBracket   = isPunct(peekToken(st), LBracket)
  if not isGenericKw and not isBracket {
    None
  } else {
    val startTok = peek(st)
    if isGenericKw { val _ = advance(st) }
    match tryEatPunct(st, LBracket) {
      case Some(_) -> {}
      case None -> {
        emitErr(st, "P0091", "expected '[' to open generic parameter list", peekSpan(st))
      }
    }
    val xs: List[GenericParam] = newList()
    if not isPunct(peekToken(st), RBracket) {
      xs.add(parseGenericParam(st))
      var keepGoing = true
      while keepGoing {
        if isPunct(peekToken(st), Comma) {
          val _ = advance(st)
          if not isPunct(peekToken(st), RBracket) {
            xs.add(parseGenericParam(st))
          }
        } else {
          keepGoing = false
        }
      }
    }
    val endSpan = match tryEatPunct(st, RBracket) {
      case Some(t) -> t.span
      case None -> {
        emitErr(st, "P0092", "expected ']' to close generic parameter list", peekSpan(st))
        startTok.span
      }
    }
    Some(value = GenericParams(params = xs, span = joinSpans(startTok.span, endSpan)))
  }
}

pub func parseConstraintRef(st: inout ParseState): ConstraintRef {
  val head = parseModulePath(st)
  if isPunct(peekToken(st), LBracket) {
    val args = parseTypeArgs(st)
    val lastSpan = if args.count == 0 { head.span } else {
      match args[args.count - 1] {
        case TAType(ty) -> ty.span
        case TAValue(e) -> e.span
      }
    }
    ConstraintRef(head = head, args = args, span = joinSpans(head.span, lastSpan))
  } else {
    val emptyArgs: List[TypeArg] = newList()
    ConstraintRef(head = head, args = emptyArgs, span = head.span)
  }
}

pub func parseWhereClauseOpt(st: inout ParseState): Option[WhereClause] {
  if not isKw(peekToken(st), KwWhere) {
    None
  } else {
    val startTok = advance(st)
    val xs: List[WhereBound] = newList()
    // First bound.
    val nameTok = peek(st)
    val name = match tryEatIdent(st) {
      case Some(ns) -> ns
      case None -> {
        emitErr(st, "P0093", "expected an identifier in where-bound", nameTok.span)
        NameAndSpan(name = "<error>", span = nameTok.span)
      }
    }
    match tryEatPunct(st, Colon) {
      case Some(_) -> {}
      case None -> {
        emitErr(st, "P0094", "expected ':' after the bound's type variable", peekSpan(st))
      }
    }
    val constraints: List[ConstraintRef] = newList()
    constraints.add(parseConstraintRef(st))
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Plus) {
        val _ = advance(st)
        constraints.add(parseConstraintRef(st))
      } else {
        keepGoing = false
      }
    }
    val lastSp = constraints[constraints.count - 1].span
    xs.add(WhereBound(name = name.name, constraints = constraints,
                      span = joinSpans(name.span, lastSp)))
    // Additional bounds separated by commas.
    var keepBounds = true
    while keepBounds {
      if isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        val nb = peek(st)
        val n2 = match tryEatIdent(st) {
          case Some(ns) -> ns
          case None -> {
            emitErr(st, "P0093", "expected an identifier in where-bound", nb.span)
            NameAndSpan(name = "<error>", span = nb.span)
          }
        }
        match tryEatPunct(st, Colon) {
          case Some(_) -> {}
          case None -> {
            emitErr(st, "P0094", "expected ':' after the bound's type variable", peekSpan(st))
          }
        }
        val cs: List[ConstraintRef] = newList()
        cs.add(parseConstraintRef(st))
        var keepCs = true
        while keepCs {
          if isPunct(peekToken(st), Plus) {
            val _ = advance(st)
            cs.add(parseConstraintRef(st))
          } else {
            keepCs = false
          }
        }
        val ls2 = cs[cs.count - 1].span
        xs.add(WhereBound(name = n2.name, constraints = cs,
                          span = joinSpans(n2.span, ls2)))
      } else {
        keepBounds = false
      }
    }
    val endSpan = xs[xs.count - 1].span
    Some(value = WhereClause(bounds = xs, span = joinSpans(startTok.span, endSpan)))
  }
}

pub func parseInvariantClause(st: inout ParseState): InvariantClause {
  val startTok = advance(st)  // 'invariant'
  match tryEatPunct(st, Colon) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0095", "expected ':' after 'invariant'", peekSpan(st))
    }
  }
  val expr = parseExpr(st)
  InvariantClause(expr = expr, span = joinSpans(startTok.span, expr.span))
}

pub func parseLoopInvariants(st: inout ParseState): List[InvariantClause] {
  val xs: List[InvariantClause] = newList()
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    if isKw(peekToken(st), KwInvariant) {
      xs.add(parseInvariantClause(st))
    } else {
      keepGoing = false
    }
  }
  xs
}

pub func prependLoopInvariants(invs: in List[InvariantClause], body: in Block): Block {
  if invs.count == 0 {
    body
  } else {
    val newStmts: List[Statement] = newList()
    var i = 0
    while i < invs.count {
      newStmts.add(Statement(kind = SInvariant(expr = invs[i].expr), span = invs[i].span))
      i = i + 1
    }
    var j = 0
    while j < body.statements.count {
      newStmts.add(body.statements[j])
      j = j + 1
    }
    Block(statements = newStmts, span = body.span)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Range bounds.
// ─────────────────────────────────────────────────────────────────────────────

pub func parseRangeBound(st: inout ParseState): RangeBound {
  if isPunct(peekToken(st), DotDotEq) {
    val _ = advance(st)
    val hi = parseExpr(st)
    RBLowerOpen(hi = hi)
  } else if isPunct(peekToken(st), DotDot) or isPunct(peekToken(st), DotDotLt) {
    val opTok = advance(st)
    val hi = parseExpr(st)
    val lo = mkExpr(ELiteral(lit = LInt(value = 0i64, suffix = NoIntSuffix)), opTok.span)
    RBHalfOpen(lo = lo, hi = hi)
  } else {
    val lo = parseExpr(st)
    if isPunct(peekToken(st), DotDotEq) {
      val _ = advance(st)
      val hi = parseExpr(st)
      RBClosed(lo = lo, hi = hi)
    } else if isPunct(peekToken(st), DotDotLt) {
      val _ = advance(st)
      val hi = parseExpr(st)
      RBHalfOpen(lo = lo, hi = hi)
    } else if isPunct(peekToken(st), DotDot) {
      val _ = advance(st)
      // `lo ..` (upper-open) or `lo .. hi` (half-open).
      val nextTok = peekToken(st)
      val isEnd =
        match nextTok {
          case TStmtEnd -> true
          case TPunct(p) -> {
            match p {
              case Comma -> true
              case RParen -> true
              case RBracket -> true
              case RBrace -> true
              case _ -> false
            }
          }
          case TEof -> true
          case _ -> false
        }
      if isEnd {
        RBUpperOpen(lo = lo)
      } else {
        val hi = parseExpr(st)
        RBHalfOpen(lo = lo, hi = hi)
      }
    } else {
      emitErr(st, "P0060", "expected '..', '..<', or '..=' in range bound", peekSpan(st))
      RBClosed(lo = lo, hi = lo)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Type arguments and type expressions.
// ─────────────────────────────────────────────────────────────────────────────

func parseTypeArg(st: inout ParseState): TypeArg {
  match peekToken(st) {
    case TInt(_, _)          -> TAValue(expr = parseExpr(st))
    case TFloat(_, _)        -> TAValue(expr = parseExpr(st))
    case TChar(_)            -> TAValue(expr = parseExpr(st))
    case TString(_)          -> TAValue(expr = parseExpr(st))
    case TTripleString(_)    -> TAValue(expr = parseExpr(st))
    case TRawString(_)       -> TAValue(expr = parseExpr(st))
    case TBool(_)            -> TAValue(expr = parseExpr(st))
    case TPunct(p) -> {
      match p {
        case Minus -> TAValue(expr = parseExpr(st))
        case _ -> TAType(ty = parseTypeExpr(st))
      }
    }
    case _ -> TAType(ty = parseTypeExpr(st))
  }
}

pub func parseTypeArgs(st: inout ParseState): List[TypeArg] {
  val _ = advance(st)  // '['
  val xs: List[TypeArg] = newList()
  if not isPunct(peekToken(st), RBracket) {
    xs.add(parseTypeArg(st))
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RBracket) {
          xs.add(parseTypeArg(st))
        }
      } else {
        keepGoing = false
      }
    }
  }
  match tryEatPunct(st, RBracket) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0061", "expected ']' to close type-argument list", peekSpan(st))
    }
  }
  xs
}

func applyNullableSuffix(st: inout ParseState, t: in TypeExpr): TypeExpr {
  if isPunct(peekToken(st), Question) {
    val qTok = advance(st)
    mkType(TNullable(inner = t), joinSpans(t.span, qTok.span))
  } else {
    t
  }
}

func parseTypeListUntilRParen(st: inout ParseState): List[TypeExpr] {
  val xs: List[TypeExpr] = newList()
  if not isPunct(peekToken(st), RParen) {
    xs.add(parseTypeExpr(st))
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RParen) {
          xs.add(parseTypeExpr(st))
        }
      } else {
        keepGoing = false
      }
    }
  }
  xs
}

func parseAtomNonParenType(st: inout ParseState): TypeExpr {
  val tok = peek(st)
  match tok.token {
    case TIdent(name) -> {
      if name == "Self" {
        val _ = advance(st)
        mkType(TSelf, tok.span)
      } else if name == "Never" {
        val _ = advance(st)
        mkType(TNever, tok.span)
      } else if name == "array" and isPunct(peekAt(st, 1).token, LBracket) {
        val _ = advance(st)
        val _ = advance(st)  // '['
        val size = parseTypeArg(st)
        match tryEatPunct(st, Comma) {
          case Some(_) -> {}
          case None -> {
            emitErr(st, "P0062", "expected ',' between size and element type in array[...]", peekSpan(st))
          }
        }
        val elem = parseTypeExpr(st)
        val endSpan = match tryEatPunct(st, RBracket) {
          case Some(t) -> t.span
          case None -> {
            emitErr(st, "P0061", "expected ']' to close array[...]", peekSpan(st))
            elem.span
          }
        }
        mkType(TArray(size = size, element = elem), joinSpans(tok.span, endSpan))
      } else if name == "slice" and isPunct(peekAt(st, 1).token, LBracket) {
        val _ = advance(st)
        val _ = advance(st)  // '['
        val elem = parseTypeExpr(st)
        val endSpan = match tryEatPunct(st, RBracket) {
          case Some(t) -> t.span
          case None -> {
            emitErr(st, "P0061", "expected ']' to close slice[...]", peekSpan(st))
            elem.span
          }
        }
        mkType(TSlice(element = elem), joinSpans(tok.span, endSpan))
      } else {
        val path = parseModulePath(st)
        if isPunct(peekToken(st), LBracket) {
          val args = parseTypeArgs(st)
          val lastSpan = if args.count == 0 { path.span } else {
            match args[args.count - 1] {
              case TAType(ty) -> ty.span
              case TAValue(e) -> e.span
            }
          }
          mkType(TGenericApp(head = path, args = args), joinSpans(path.span, lastSpan))
        } else if identStr(peekToken(st)) == "range" {
          val _ = advance(st)
          val bound = parseRangeBound(st)
          val endSpan = match bound {
            case RBClosed(_, hi)   -> hi.span
            case RBHalfOpen(_, hi) -> hi.span
            case RBLowerOpen(hi)   -> hi.span
            case RBUpperOpen(lo)   -> lo.span
          }
          mkType(TRefined(underlying = path, range = bound), joinSpans(path.span, endSpan))
        } else {
          mkType(TRef(path = path), path.span)
        }
      }
    }
    case _ -> {
      emitErr(st, "P0050", "expected a type", tok.span)
      if not isAtEnd(st) { val _ = advance(st) }
      mkType(TError, tok.span)
    }
  }
}

// parseTypeExprNoArrow: parse a type without consuming a trailing '->'.
pub func parseTypeExprNoArrow(st: inout ParseState): TypeExpr {
  val startSpan = peekSpan(st)
  if isPunct(peekToken(st), LParen) {
    val _ = advance(st)
    val inner = parseTypeListUntilRParen(st)
    val closeSpan = match tryEatPunct(st, RParen) {
      case Some(t) -> t.span
      case None -> {
        emitErr(st, "P0063", "expected ')' to close parenthesised type", peekSpan(st))
        startSpan
      }
    }
    val span = joinSpans(startSpan, closeSpan)
    val nodeKind =
      if inner.count == 0 { TUnit }
      else if inner.count == 1 { TParen(inner = inner[0]) }
      else { TTuple(types = inner) }
    applyNullableSuffix(st, mkType(nodeKind, span))
  } else {
    val atom = parseAtomNonParenType(st)
    applyNullableSuffix(st, atom)
  }
}

pub func parseTypeExpr(st: inout ParseState): TypeExpr {
  val startSpan = peekSpan(st)
  if isPunct(peekToken(st), LParen) {
    val _ = advance(st)
    val inner = parseTypeListUntilRParen(st)
    val closeSpan = match tryEatPunct(st, RParen) {
      case Some(t) -> t.span
      case None -> {
        emitErr(st, "P0063", "expected ')' to close parenthesised type", peekSpan(st))
        startSpan
      }
    }
    if isPunct(peekToken(st), Arrow) {
      val _ = advance(st)
      val retTy = parseTypeExpr(st)
      mkType(TFunction(parameters = inner, retTy = retTy), joinSpans(startSpan, retTy.span))
    } else {
      val span = joinSpans(startSpan, closeSpan)
      val nodeKind =
        if inner.count == 0 { TUnit }
        else if inner.count == 1 { TParen(inner = inner[0]) }
        else { TTuple(types = inner) }
      applyNullableSuffix(st, mkType(nodeKind, span))
    }
  } else {
    val atom = parseAtomNonParenType(st)
    val withSuffix = applyNullableSuffix(st, atom)
    if isPunct(peekToken(st), Arrow) {
      val _ = advance(st)
      val retTy = parseTypeExpr(st)
      val paramList: List[TypeExpr] = newList()
      paramList.add(withSuffix)
      mkType(TFunction(parameters = paramList, retTy = retTy),
             joinSpans(withSuffix.span, retTy.span))
    } else {
      withSuffix
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Patterns.
// ─────────────────────────────────────────────────────────────────────────────

// Helper record to return (fields, ignoreRest) without a tuple.
record RecordPatternResult {
  fields:     List[RecordPatternField]
  ignoreRest: Bool
}

func parseRecordPatternFields(st: inout ParseState): RecordPatternResult {
  val _ = advance(st)  // '{'
  val fields: List[RecordPatternField] = newList()
  var ignoreRest = false
  var keepGoing = true
  while keepGoing {
    if isPunct(peekToken(st), RBrace) {
      keepGoing = false
    } else if isPunct(peekToken(st), DotDot) {
      val _ = advance(st)
      ignoreRest = true
      keepGoing = false
    } else {
      match peekToken(st) {
        case TIdent(name) -> {
          val nameTok = advance(st)
          if isPunct(peekToken(st), Eq) {
            val _ = advance(st)
            val pat = parsePattern(st)
            fields.add(RPFNamed(name = name, pattern = pat,
                                span = joinSpans(nameTok.span, pat.span)))
          } else {
            fields.add(RPFShort(name = name, span = nameTok.span))
          }
          if isPunct(peekToken(st), Comma) { val _ = advance(st) }
        }
        case _ -> {
          emitErr(st, "P0070", "expected a field name or '..' in record pattern", peekSpan(st))
          keepGoing = false
        }
      }
    }
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0071", "expected '}' to close record pattern", peekSpan(st))
    }
  }
  RecordPatternResult(fields = fields, ignoreRest = ignoreRest)
}

func parsePatternArgs(st: inout ParseState): List[Pattern] {
  val _ = advance(st)  // '('
  val xs: List[Pattern] = newList()
  if not isPunct(peekToken(st), RParen) {
    xs.add(parsePattern(st))
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RParen) {
          xs.add(parsePattern(st))
        }
      } else {
        keepGoing = false
      }
    }
  }
  match tryEatPunct(st, RParen) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0072", "expected ')' to close constructor-pattern arguments", peekSpan(st))
    }
  }
  xs
}

func parsePrimaryPattern(st: inout ParseState): Pattern {
  val tok = peek(st)
  match tok.token {
    case TIdent(name) -> {
      if name == "_" {
        val _ = advance(st)
        mkPat(PWildcard, tok.span)
      } else {
        val path = parseModulePath(st)
        if isPunct(peekToken(st), LParen) {
          val args = parsePatternArgs(st)
          val lastSpan = if args.count == 0 { path.span } else { args[args.count - 1].span }
          mkPat(PConstructor(head = path, args = args), joinSpans(path.span, lastSpan))
        } else if isPunct(peekToken(st), LBrace) {
          val res = parseRecordPatternFields(st)
          mkPat(PRecord(head = path, fields = res.fields, ignoreRest = res.ignoreRest),
                joinSpans(path.span, peekSpan(st)))
        } else if isPunct(peekToken(st), At) and path.segments.count == 1 {
          val _ = advance(st)
          val inner = parsePrimaryPattern(st)
          mkPat(PBinding(name = path.segments[0], inner = Some(value = inner)),
                joinSpans(path.span, inner.span))
        } else if path.segments.count == 1 {
          val noInner: Option[Pattern] = None
          mkPat(PBinding(name = path.segments[0], inner = noInner), path.span)
        } else {
          mkPat(PConstructor(head = path, args = newList()), path.span)
        }
      }
    }
    case TKeyword(k) -> {
      match k {
        case KwResult -> {
          val _ = advance(st)
          val noInner: Option[Pattern] = None
          mkPat(PBinding(name = "result", inner = noInner), tok.span)
        }
        case _ -> {
          // Literal-led patterns: TBool.
          val firstExpr = parseExpr(st)
          mkPat(PLiteral(lit = LBool(value = false)), firstExpr.span)
        }
      }
    }
    case TInt(_, _) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TFloat(_, _) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TChar(_) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TString(_) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TBool(b) -> {
      val _ = advance(st)
      mkPat(PLiteral(lit = LBool(value = b)), tok.span)
    }
    case TTripleString(_) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TRawString(_) -> {
      val firstExpr = parseExpr(st)
      parseLiteralOrRangePat(st, firstExpr)
    }
    case TPunct(p) -> {
      match p {
        case Minus -> {
          val firstExpr = parseExpr(st)
          parseLiteralOrRangePat(st, firstExpr)
        }
        case LParen -> {
          val _ = advance(st)
          if isPunct(peekToken(st), RParen) {
            val endTok = advance(st)
            val emptyPats: List[Pattern] = newList()
            mkPat(PTuple(patterns = emptyPats), joinSpans(tok.span, endTok.span))
          } else {
            val first = parsePattern(st)
            if isPunct(peekToken(st), Comma) {
              val items: List[Pattern] = newList()
              items.add(first)
              var keepGoing = true
              while keepGoing {
                if isPunct(peekToken(st), Comma) {
                  val _ = advance(st)
                  if not isPunct(peekToken(st), RParen) {
                    items.add(parsePattern(st))
                  }
                } else {
                  keepGoing = false
                }
              }
              val endSpan = match tryEatPunct(st, RParen) {
                case Some(t) -> t.span
                case None -> {
                  emitErr(st, "P0074", "expected ')' to close tuple pattern", peekSpan(st))
                  first.span
                }
              }
              mkPat(PTuple(patterns = items), joinSpans(tok.span, endSpan))
            } else {
              val endSpan = match tryEatPunct(st, RParen) {
                case Some(t) -> t.span
                case None -> {
                  emitErr(st, "P0074", "expected ')' to close paren pattern", peekSpan(st))
                  first.span
                }
              }
              mkPat(PParen(inner = first), joinSpans(tok.span, endSpan))
            }
          }
        }
        case _ -> {
          emitErr(st, "P0075", "expected a pattern", tok.span)
          if not isAtEnd(st) { val _ = advance(st) }
          mkPat(PError, tok.span)
        }
      }
    }
    case _ -> {
      emitErr(st, "P0075", "expected a pattern", tok.span)
      if not isAtEnd(st) { val _ = advance(st) }
      mkPat(PError, tok.span)
    }
  }
}

// Helper: given a parsed expression, check for a range suffix or
// convert to a literal pattern.
func parseLiteralOrRangePat(st: inout ParseState, firstExpr: in Expr): Pattern {
  if isPunct(peekToken(st), DotDotEq) {
    val _ = advance(st)
    val hi = parseExpr(st)
    mkPat(PRange(lo = firstExpr, inclusive = true, hi = hi),
          joinSpans(firstExpr.span, hi.span))
  } else if isPunct(peekToken(st), DotDot) or isPunct(peekToken(st), DotDotLt) {
    val _ = advance(st)
    val hi = parseExpr(st)
    mkPat(PRange(lo = firstExpr, inclusive = false, hi = hi),
          joinSpans(firstExpr.span, hi.span))
  } else {
    match firstExpr.kind {
      case ELiteral(lit) -> mkPat(PLiteral(lit = lit), firstExpr.span)
      case EPrefix(op, inner) -> {
        match op {
          case PreNeg -> {
            match inner.kind {
              case ELiteral(lit) -> {
                match lit {
                  case LInt(v, sfx) -> {
                    val negV = 0 - v
                    mkPat(PLiteral(lit = LInt(value = negV, suffix = sfx)), firstExpr.span)
                  }
                  case LFloat(v, sfx) -> {
                    val negV = 0.0 - v
                    mkPat(PLiteral(lit = LFloat(value = negV, suffix = sfx)), firstExpr.span)
                  }
                  case _ -> {
                    emitErr(st, "P0073", "expected a literal pattern", firstExpr.span)
                    mkPat(PError, firstExpr.span)
                  }
                }
              }
              case _ -> {
                emitErr(st, "P0073", "expected a literal pattern", firstExpr.span)
                mkPat(PError, firstExpr.span)
              }
            }
          }
          case _ -> {
            emitErr(st, "P0073", "expected a literal pattern", firstExpr.span)
            mkPat(PError, firstExpr.span)
          }
        }
      }
      case _ -> {
        emitErr(st, "P0073", "expected a literal pattern", firstExpr.span)
        mkPat(PError, firstExpr.span)
      }
    }
  }
}

func parseTypeTestPattern(st: inout ParseState): Pattern {
  val primary = parsePrimaryPattern(st)
  if isKw(peekToken(st), KwIs) {
    val _ = advance(st)
    val ty = parseTypeExpr(st)
    mkPat(PTypeTest(inner = primary, ty = ty), joinSpans(primary.span, ty.span))
  } else {
    primary
  }
}

pub func parsePattern(st: inout ParseState): Pattern {
  val first = parseTypeTestPattern(st)
  if isPunct(peekToken(st), Pipe) {
    val alts: List[Pattern] = newList()
    alts.add(first)
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Pipe) {
        val _ = advance(st)
        alts.add(parseTypeTestPattern(st))
      } else {
        keepGoing = false
      }
    }
    val lastSpan = alts[alts.count - 1].span
    mkPat(POr(patterns = alts), joinSpans(first.span, lastSpan))
  } else {
    first
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expressions — primary, postfix, prefix, binary precedence cascade.
// ─────────────────────────────────────────────────────────────────────────────

pub func parsePrimaryExpr(st: inout ParseState): Expr {
  val tok = peek(st)
  match tok.token {
    case TInt(_, _) -> {
      val t = advance(st)
      match t.token {
        case TInt(v, sfx) -> mkExpr(ELiteral(lit = LInt(value = v, suffix = sfx)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TFloat(_, _) -> {
      val t = advance(st)
      match t.token {
        case TFloat(v, sfx) -> mkExpr(ELiteral(lit = LFloat(value = v, suffix = sfx)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TChar(_) -> {
      val t = advance(st)
      match t.token {
        case TChar(cp) -> mkExpr(ELiteral(lit = LChar(codepoint = cp)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TString(_) -> {
      val t = advance(st)
      match t.token {
        case TString(s) -> mkExpr(ELiteral(lit = LString(text = s)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TTripleString(_) -> {
      val t = advance(st)
      match t.token {
        case TTripleString(s) -> mkExpr(ELiteral(lit = LTripleString(text = s)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TRawString(_) -> {
      val t = advance(st)
      match t.token {
        case TRawString(s) -> mkExpr(ELiteral(lit = LRawString(text = s)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TBool(_) -> {
      val t = advance(st)
      match t.token {
        case TBool(b) -> mkExpr(ELiteral(lit = LBool(value = b)), t.span)
        case _ -> mkExpr(EError, t.span)
      }
    }
    case TStringStart -> {
      val startTok = advance(st)
      val segs: List[InterpolatedSegment] = newList()
      var closed = false
      while not closed {
        match peekToken(st) {
          case TStringPart(s) -> {
            val t = advance(st)
            if s.length > 0 { segs.add(ISText(text = s, span = t.span)) }
          }
          case TStringHoleStart -> {
            val _ = advance(st)
            val inner = parseExpr(st)
            segs.add(ISExpr(expr = inner))
            match tryEatPunct(st, RBrace) {
              case Some(_) -> {}
              case None -> {
                emitErr(st, "P0150", "expected '}' to close interpolation hole", peekSpan(st))
              }
            }
          }
          case TStringEnd -> {
            val _ = advance(st)
            closed = true
          }
          case _ -> {
            emitErr(st, "P0151", "unexpected token inside interpolated string", peekSpan(st))
            closed = true
          }
        }
      }
      mkExpr(EInterpolated(segments = segs), joinSpans(startTok.span, peekSpan(st)))
    }
    case TPunct(p) -> {
      match p {
        case LParen -> {
          // Check for `(Ident range ...)`  type-as-expression form.
          val isTypeExpr =
            (match peekAt(st, 1).token { case TIdent(_) -> true; case _ -> false }) and
            (identStr(peekAt(st, 2).token) == "range")
          if isTypeExpr {
            val _ = advance(st)
            val ty = parseTypeExprNoArrow(st)
            val _ = match tryEatPunct(st, RParen) {
              case Some(t) -> t.span
              case None -> {
                emitErr(st, "P0051", "expected ')' to close parenthesised type expression", peekSpan(st))
                ty.span
              }
            }
            val head = match ty.kind {
              case TRefined(mp, _) -> mp
              case TRef(mp)        -> mp
              case _ -> ModulePath(segments = newList(), span = ty.span)
            }
            mkExpr(EPath(path = head), joinSpans(tok.span, ty.span))
          } else {
            val _ = advance(st)
            if isPunct(peekToken(st), RParen) {
              val endTok = advance(st)
              mkExpr(ELiteral(lit = LUnit), joinSpans(tok.span, endTok.span))
            } else {
              val inner = parseExpr(st)
              if isPunct(peekToken(st), Comma) {
                val items: List[Expr] = newList()
                items.add(inner)
                var keepGoing = true
                while keepGoing {
                  if isPunct(peekToken(st), Comma) {
                    val _ = advance(st)
                    if not isPunct(peekToken(st), RParen) {
                      items.add(parseExpr(st))
                    }
                  } else {
                    keepGoing = false
                  }
                }
                val endSpan = match tryEatPunct(st, RParen) {
                  case Some(t) -> t.span
                  case None -> {
                    emitErr(st, "P0051", "expected ')' to close tuple expression", peekSpan(st))
                    items[items.count - 1].span
                  }
                }
                mkExpr(ETuple(exprs = items), joinSpans(tok.span, endSpan))
              } else {
                val endSpan = match tryEatPunct(st, RParen) {
                  case Some(t) -> t.span
                  case None -> {
                    emitErr(st, "P0051", "expected ')' to close parenthesised expression", peekSpan(st))
                    inner.span
                  }
                }
                mkExpr(EParen(inner = inner), joinSpans(tok.span, endSpan))
              }
            }
          }
        }
        case LBracket -> {
          val startTok = advance(st)
          val xs: List[Expr] = newList()
          if not isPunct(peekToken(st), RBracket) {
            xs.add(parseExpr(st))
            var keepGoing = true
            while keepGoing {
              if isPunct(peekToken(st), Comma) {
                val _ = advance(st)
                if not isPunct(peekToken(st), RBracket) {
                  xs.add(parseExpr(st))
                }
              } else {
                keepGoing = false
              }
            }
          }
          val endSpan = match tryEatPunct(st, RBracket) {
            case Some(t) -> t.span
            case None -> {
              emitErr(st, "P0192", "expected ']' to close list literal", peekSpan(st))
              startTok.span
            }
          }
          mkExpr(EList(exprs = xs), joinSpans(startTok.span, endSpan))
        }
        case LBrace -> parseLambdaExpr(st)
        case _ -> {
          emitErr(st, "P0050", "expected an expression", tok.span)
          val _ = advance(st)
          mkExpr(EError, tok.span)
        }
      }
    }
    case TKeyword(k) -> {
      match k {
        case KwSelf -> {
          val _ = advance(st)
          mkExpr(ESelf, tok.span)
        }
        case KwResult -> {
          val _ = advance(st)
          mkExpr(EResult, tok.span)
        }
        case KwIf -> parseIfExpr(st)
        case KwMatch -> parseMatchExpr(st)
        case KwAwait -> {
          val opTok = advance(st)
          val inner = parsePostfixExpr(st)
          mkExpr(EAwait(inner = inner), joinSpans(opTok.span, inner.span))
        }
        case KwYield -> {
          val opTok = advance(st)
          // `yield` uses expression (assignment) precedence so `yield a * 2`
          // parses as `yield (a * 2)`, matching the spec §7.2 and D071.
          // `await` and `spawn` use postfix precedence (parsePostfixExpr).
          val inner = parseExpr(st)
          mkExpr(EYield(inner = inner), joinSpans(opTok.span, inner.span))
        }
        case KwSpawn -> {
          val opTok = advance(st)
          val inner = parsePostfixExpr(st)
          mkExpr(ESpawn(inner = inner), joinSpans(opTok.span, inner.span))
        }
        case KwOld -> {
          val opTok = advance(st)
          match tryEatPunct(st, LParen) {
            case Some(_) -> {}
            case None -> {
              emitErr(st, "P0190", "expected '(' after 'old'", peekSpan(st))
            }
          }
          val inner = parseExpr(st)
          val endSpan = match tryEatPunct(st, RParen) {
            case Some(t) -> t.span
            case None -> {
              emitErr(st, "P0191", "expected ')' to close 'old(...)'", peekSpan(st))
              inner.span
            }
          }
          mkExpr(EOld(inner = inner), joinSpans(opTok.span, endSpan))
        }
        case KwReturn -> {
          val stmt = parseStatement(st)
          val blk = Block(statements = singletonList(stmt), span = stmt.span)
          mkExpr(EBlock(block = blk), stmt.span)
        }
        case KwThrow -> {
          val stmt = parseStatement(st)
          val blk = Block(statements = singletonList(stmt), span = stmt.span)
          mkExpr(EBlock(block = blk), stmt.span)
        }
        case KwTry -> {
          val stmt = parseStatement(st)
          val blk = Block(statements = singletonList(stmt), span = stmt.span)
          mkExpr(EBlock(block = blk), stmt.span)
        }
        case _ -> {
          emitErr(st, "P0050", "expected an expression", tok.span)
          val _ = advance(st)
          mkExpr(EError, tok.span)
        }
      }
    }
    case TIdent(name) -> {
      if name == "unsafe" {
        val opTok = advance(st)
        val body = parseBlock(st)
        mkExpr(EUnsafe(block = body), joinSpans(opTok.span, body.span))
      } else if name == "forall" {
        parseQuantifierExpr(st, true)
      } else if name == "exists" {
        parseQuantifierExpr(st, false)
      } else if name == "break" {
        val stmt = parseStatement(st)
        val blk = Block(statements = singletonList(stmt), span = stmt.span)
        mkExpr(EBlock(block = blk), stmt.span)
      } else if name == "continue" {
        val stmt = parseStatement(st)
        val blk = Block(statements = singletonList(stmt), span = stmt.span)
        mkExpr(EBlock(block = blk), stmt.span)
      } else {
        val nameTok = advance(st)
        val nm = identStr(nameTok.token)
        val segs: List[String] = newList()
        segs.add(nm)
        val path = ModulePath(segments = segs, span = nameTok.span)
        mkExpr(EPath(path = path), nameTok.span)
      }
    }
    case _ -> {
      emitErr(st, "P0050", "expected an expression", tok.span)
      val _ = advance(st)
      mkExpr(EError, tok.span)
    }
  }
}

// Small helper: make a list with a single element (avoids newList + add dance
// in expression position where the list is not used again).
func singletonList(stmt: in Statement): List[Statement] {
  val xs: List[Statement] = newList()
  xs.add(stmt)
  xs
}

pub func parsePostfixExpr(st: inout ParseState): Expr {
  var e = parsePrimaryExpr(st)
  var keep = true
  while keep {
    if isPunct(peekToken(st), LParen) {
      val _ = advance(st)
      val args: List[CallArg] = newList()
      if not isPunct(peekToken(st), RParen) {
        args.add(parseCallArg(st))
        var keepArgs = true
        while keepArgs {
          if isPunct(peekToken(st), Comma) {
            val _ = advance(st)
            if not isPunct(peekToken(st), RParen) {
              args.add(parseCallArg(st))
            }
          } else {
            keepArgs = false
          }
        }
      }
      val endSpan = match tryEatPunct(st, RParen) {
        case Some(t) -> t.span
        case None -> {
          emitErr(st, "P0080", "expected ')' to close call argument list", peekSpan(st))
          e.span
        }
      }
      e = mkExpr(ECall(fn = e, args = args), joinSpans(e.span, endSpan))
    } else if isPunct(peekToken(st), Dot) {
      val _ = advance(st)
      match tryEatIdent(st) {
        case Some(ns) -> {
          e = mkExpr(EMember(receiver = e, memberName = ns.name), joinSpans(e.span, ns.span))
        }
        case None -> {
          emitErr(st, "P0081", "expected an identifier after '.'", peekSpan(st))
          keep = false
        }
      }
    } else if isPunct(peekToken(st), Question) {
      val qTok = advance(st)
      e = mkExpr(EPropagate(inner = e), joinSpans(e.span, qTok.span))
    } else if isPunct(peekToken(st), LBracket) {
      val _ = advance(st)
      val xs: List[Expr] = newList()
      if not isPunct(peekToken(st), RBracket) {
        xs.add(parseExpr(st))
        var keepIdx = true
        while keepIdx {
          if isPunct(peekToken(st), Comma) {
            val _ = advance(st)
            if not isPunct(peekToken(st), RBracket) {
              xs.add(parseExpr(st))
            }
          } else {
            keepIdx = false
          }
        }
      }
      val endSpan = match tryEatPunct(st, RBracket) {
        case Some(t) -> t.span
        case None -> {
          emitErr(st, "P0083", "expected ']' to close index expression", peekSpan(st))
          e.span
        }
      }
      e = mkExpr(EIndex(receiver = e, indices = xs), joinSpans(e.span, endSpan))
    } else {
      keep = false
    }
  }
  e
}

func parseCallArg(st: inout ParseState): CallArg {
  val saved = mark(st)
  match peekToken(st) {
    case TIdent(name) -> {
      val nameTok = advance(st)
      if isPunct(peekToken(st), Eq) {
        val _ = advance(st)
        val value = parseExpr(st)
        CANamed(name = name, value = value, span = joinSpans(nameTok.span, value.span))
      } else {
        reset(st, saved)
        CAPositional(expr = parseExpr(st))
      }
    }
    case _ -> CAPositional(expr = parseExpr(st))
  }
}

pub func parseIfExpr(st: inout ParseState): Expr {
  val startTok = advance(st)  // 'if'
  val cond = parseExpr(st)
  if isKw(peekToken(st), KwThen) {
    val _ = advance(st)
    val thenExpr = parseExpr(st)
    match tryEatKw(st, KwElse) {
      case Some(_) -> {}
      case None -> {
        emitErr(st, "P0200", "expected 'else' in `if … then … else …` expression", peekSpan(st))
      }
    }
    val elseExpr = parseExpr(st)
    mkExpr(EIf(cond = cond,
               thenBranch = EOBExpr(expr = thenExpr),
               elseBranch = Some(value = EOBExpr(expr = elseExpr)),
               thenForm = true),
           joinSpans(startTok.span, elseExpr.span))
  } else {
    val thenBlock = parseBlock(st)
    val elseBranch: Option[ExprOrBlock] =
      if isKw(peekToken(st), KwElse) {
        val _ = advance(st)
        if isKw(peekToken(st), KwIf) {
          val elseIf = parseIfExpr(st)
          Some(value = EOBExpr(expr = elseIf))
        } else {
          val blk = parseBlock(st)
          Some(value = EOBBlock(block = blk))
        }
      } else {
        None
      }
    val endSpan = match elseBranch {
      case Some(eob) -> {
        match eob {
          case EOBExpr(e)  -> e.span
          case EOBBlock(b) -> b.span
        }
      }
      case None -> thenBlock.span
    }
    mkExpr(EIf(cond = cond,
               thenBranch = EOBBlock(block = thenBlock),
               elseBranch = elseBranch,
               thenForm = false),
           joinSpans(startTok.span, endSpan))
  }
}

func parseMatchArmBody(st: inout ParseState): ExprOrBlock {
  if isPunct(peekToken(st), LBrace) {
    EOBBlock(block = parseBlock(st))
  } else if isKw(peekToken(st), KwReturn) or isKw(peekToken(st), KwThrow) {
    val stmt = parseStatement(st)
    val stmts: List[Statement] = newList()
    stmts.add(stmt)
    EOBBlock(block = Block(statements = stmts, span = stmt.span))
  } else if identStr(peekToken(st)) == "break" or identStr(peekToken(st)) == "continue" {
    val stmt = parseStatement(st)
    val stmts: List[Statement] = newList()
    stmts.add(stmt)
    EOBBlock(block = Block(statements = stmts, span = stmt.span))
  } else {
    EOBExpr(expr = parseExpr(st))
  }
}

func parseMatchArm(st: inout ParseState): MatchArm {
  val startSpan = peekSpan(st)
  match tryEatKw(st, KwCase) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0201", "expected 'case' to start a match arm", peekSpan(st))
    }
  }
  val pat = parsePattern(st)
  val guard: Option[Expr] =
    if isKw(peekToken(st), KwWhere) or isKw(peekToken(st), KwIf) {
      val _ = advance(st)
      Some(value = parseExpr(st))
    } else {
      None
    }
  match tryEatPunct(st, Arrow) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0202", "expected '->' after match-arm pattern", peekSpan(st))
    }
  }
  val body = parseMatchArmBody(st)
  val endSpan = match body {
    case EOBExpr(e)  -> e.span
    case EOBBlock(b) -> b.span
  }
  MatchArm(pattern = pat, guard = guard, body = body, span = joinSpans(startSpan, endSpan))
}

pub func parseMatchExpr(st: inout ParseState): Expr {
  val startTok = advance(st)  // 'match'
  val scrutinee = parseExpr(st)
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0203", "expected '{' to start match arms", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val arms: List[MatchArm] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    arms.add(parseMatchArm(st))
    if peekToken(st) == TStmtEnd or isPunct(peekToken(st), Comma) {
      val _ = advance(st)
      val _ = skipStmtEnds(st)
    } else {
      match peekToken(st) {
        case TStmtEnd -> {
          val _ = advance(st)
          val _ = skipStmtEnds(st)
        }
        case TPunct(p) -> {
          match p {
            case Comma -> {
              val _ = advance(st)
              val _ = skipStmtEnds(st)
            }
            case _ -> {}
          }
        }
        case _ -> {}
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  val endSpan = match tryEatPunct(st, RBrace) {
    case Some(t) -> t.span
    case None -> {
      emitErr(st, "P0204", "expected '}' to close match expression", peekSpan(st))
      scrutinee.span
    }
  }
  mkExpr(EMatch(scrutinee = scrutinee, arms = arms), joinSpans(startTok.span, endSpan))
}

func parseQuantifierBinder(st: inout ParseState): PropertyBinder {
  val nameTok = peek(st)
  val ns = match tryEatIdent(st) {
    case Some(n) -> n
    case None -> {
      emitErr(st, "P0300", "expected an identifier in quantifier binder", nameTok.span)
      NameAndSpan(name = "<error>", span = nameTok.span)
    }
  }
  match tryEatPunct(st, Colon) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0301", "expected ':' in quantifier binder", peekSpan(st))
    }
  }
  val ty = parseTypeExpr(st)
  PropertyBinder(name = ns.name, ty = ty, span = joinSpans(ns.span, ty.span))
}

func parseQuantifierExpr(st: inout ParseState, isForall: in Bool): Expr {
  val startTok = advance(st)  // 'forall' or 'exists'
  match tryEatPunct(st, LParen) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0302", "expected '(' after quantifier", peekSpan(st))
    }
  }
  val binders: List[PropertyBinder] = newList()
  if not isPunct(peekToken(st), RParen) {
    binders.add(parseQuantifierBinder(st))
    var keepGoing = true
    while keepGoing {
      if isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RParen) {
          binders.add(parseQuantifierBinder(st))
        }
      } else {
        keepGoing = false
      }
    }
  }
  match tryEatPunct(st, RParen) {
    case Some(_) -> {}
    case None -> {
      emitErr(st, "P0303", "expected ')' to close quantifier binder list", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val whereExpr: Option[Expr] =
    if isKw(peekToken(st), KwWhere) {
      val _ = advance(st)
      Some(value = parseOrExpr(st))
    } else {
      None
    }
  val _ = skipStmtEnds(st)
  val body =
    if identStr(peekToken(st)) == "implies" {
      val _ = advance(st)
      parseExpr(st)
    } else if isPunct(peekToken(st), LBrace) {
      val blk = parseBlock(st)
      mkExpr(EBlock(block = blk), blk.span)
    } else {
      parseExpr(st)
    }
  val kind =
    if isForall { EForall(binders = binders, whereExpr = whereExpr, body = body) }
    else        { EExists(binders = binders, whereExpr = whereExpr, body = body) }
  mkExpr(kind, joinSpans(startTok.span, body.span))
}

pub func parseLambdaExpr(st: inout ParseState): Expr {
  val startTok = advance(st)  // '{'
  val saved = mark(st)
  val _ = skipStmtEnds(st)

  // Try to detect lambda params: comma-separated `name [: type]` list
  // followed by `->`.
  val lambdaParams: List[LambdaParam] = newList()
  var hasArrow = false

  if isPunct(peekToken(st), Arrow) {
    // `{ -> body }` — zero params.
    val _ = advance(st)
    hasArrow = true
  } else if isPunct(peekToken(st), LParen) {
    // Parenthesised param list not handled in prototype; treat as body.
    reset(st, saved)
  } else {
    // Try comma-separated ident [: type] list.
    val savePos = mark(st)
    var headOk = true
    var keepTrying = true
    while keepTrying and headOk {
      match peekToken(st) {
        case TIdent(name) -> {
          val nameTok = advance(st)
          val ty: Option[TypeExpr] =
            if isPunct(peekToken(st), Colon) {
              val _ = advance(st)
              Some(value = parseTypeExprNoArrow(st))
            } else {
              None
            }
          val endSp = match ty { case Some(t) -> t.span; case None -> nameTok.span }
          lambdaParams.add(LambdaParam(name = name, ty = ty,
                                       span = joinSpans(nameTok.span, endSp)))
          if isPunct(peekToken(st), Comma) {
            val _ = advance(st)
          } else {
            keepTrying = false
          }
        }
        case _ -> {
          headOk = false
          keepTrying = false
        }
      }
    }
    if headOk and isPunct(peekToken(st), Arrow) {
      val _ = advance(st)
      hasArrow = true
    } else {
      reset(st, savePos)
      // Clear lambdaParams since we backtracked.
      var ci = lambdaParams.count - 1
      while ci >= 0 {
        // No clear() on List in stdlib; remove by rebuilding.
        ci = -1  // break
      }
      // Re-create empty list effect: we just leave lambdaParams as-is
      // but won't use it since hasArrow = false.
    }
  }

  val stmts: List[Statement] = newList()
  val _ = skipStmtEnds(st)
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    stmts.add(parseStatement(st))
    match peekToken(st) {
      case TStmtEnd -> {
        val _ = advance(st)
        val _ = skipStmtEnds(st)
      }
      case TPunct(p) -> {
        match p {
          case Semi -> {
            val _ = advance(st)
            val _ = skipStmtEnds(st)
          }
          case _ -> {}
        }
      }
      case _ -> {}
    }
    forceAdvanceIfStuck(st, before)
  }
  val endSpan = match tryEatPunct(st, RBrace) {
    case Some(t) -> t.span
    case None -> {
      emitErr(st, "P0205", "expected '}' to close lambda / block", peekSpan(st))
      startTok.span
    }
  }
  val body = Block(statements = stmts, span = joinSpans(startTok.span, endSpan))
  if hasArrow {
    mkExpr(ELambda(lambdaParams = lambdaParams, body = body),
           joinSpans(startTok.span, endSpan))
  } else {
    val emptyParams: List[LambdaParam] = newList()
    mkExpr(ELambda(lambdaParams = emptyParams, body = body),
           joinSpans(startTok.span, endSpan))
  }
}

// #425 item 5 / #1174: when `parsePrefixExpr` collapses a `-` token
// followed by the literal `9223372036854775808` into PreNeg + LInt,
// the lexer's L0010 against the bare literal is a false positive —
// the wrapper makes the value well-formed (Long.MinValue).  Walk
// the diagnostics in reverse order so we drop the most recent L0010
// whose span ends exactly at the inner literal's end, leaving any
// earlier unrelated L0010 in place.
func cancelMinValueDiagIfWrapped(st: inout ParseState, inner: in Expr): Unit {
  match inner.kind {
    case ELiteral(lit) ->
      match lit {
        case LInt(v, _) -> {
          if v == -9223372036854775808i64 {
            val innerEnd = inner.span.endPos.offset
            var i = st.diags.count - 1
            var done = false
            while not done and i >= 0 {
              val d = st.diags[i]
              if d.code == "L0010" and d.span.endPos.offset == innerEnd {
                st.diags.removeAt(i)
                done = true
              }
              i = i - 1
            }
          }
        }
        case _ -> {}
      }
    case _ -> {}
  }
}

pub func parsePrefixExpr(st: inout ParseState): Expr {
  if isPunct(peekToken(st), Minus) {
    val opTok = advance(st)
    val inner = parsePrefixExpr(st)
    // #425 item 5 / #1174: the lexer fires L0010 against a bare
    // `9223372036854775808` literal because the value only fits in
    // Long as a bit pattern.  When the literal is the operand of a
    // unary minus the pair folds to Long.MinValue and is
    // well-formed, so cancel the lexer's diagnostic here.
    cancelMinValueDiagIfWrapped(st, inner)
    mkExpr(EPrefix(op = PreNeg, operand = inner), joinSpans(opTok.span, inner.span))
  } else if isKw(peekToken(st), KwNot) {
    val opTok = advance(st)
    val inner = parsePrefixExpr(st)
    mkExpr(EPrefix(op = PreNot, operand = inner), joinSpans(opTok.span, inner.span))
  } else if isPunct(peekToken(st), Amp) {
    val opTok = advance(st)
    val inner = parsePrefixExpr(st)
    mkExpr(EPrefix(op = PreRef, operand = inner), joinSpans(opTok.span, inner.span))
  } else {
    parsePostfixExpr(st)
  }
}

func parseMulExpr(st: inout ParseState): Expr {
  var lhs = parsePrefixExpr(st)
  var keep = true
  while keep {
    if isPunct(peekToken(st), Star) {
      val _ = advance(st)
      val rhs = parsePrefixExpr(st)
      lhs = mkExpr(EBinop(op = BMul, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else if isPunct(peekToken(st), Slash) {
      val _ = advance(st)
      val rhs = parsePrefixExpr(st)
      lhs = mkExpr(EBinop(op = BDiv, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else if isPunct(peekToken(st), Percent) {
      val _ = advance(st)
      val rhs = parsePrefixExpr(st)
      lhs = mkExpr(EBinop(op = BMod, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else {
      keep = false
    }
  }
  lhs
}

func parseAddExpr(st: inout ParseState): Expr {
  var lhs = parseMulExpr(st)
  var keep = true
  while keep {
    if isPunct(peekToken(st), Plus) {
      val _ = advance(st)
      val rhs = parseMulExpr(st)
      lhs = mkExpr(EBinop(op = BAdd, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else if isPunct(peekToken(st), Minus) {
      val _ = advance(st)
      val rhs = parseMulExpr(st)
      lhs = mkExpr(EBinop(op = BSub, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else {
      keep = false
    }
  }
  lhs
}

func parseCoalesceExpr(st: inout ParseState): Expr {
  val lhs = parseAddExpr(st)
  val savedPos = mark(st)
  val _ = skipStmtEnds(st)
  if isPunct(peekToken(st), QuestionQuestion) {
    val _ = advance(st)
    val rhs = parseCoalesceExpr(st)
    mkExpr(EBinop(op = BCoalesce, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
  } else {
    reset(st, savedPos)
    lhs
  }
}

func parseCompareExpr(st: inout ParseState): Expr {
  val lhs = parseCoalesceExpr(st)
  var op: Option[BinOp] = None
  if isPunct(peekToken(st), EqEq)  { op = Some(value = BEq)  }
  else if isPunct(peekToken(st), NotEq) { op = Some(value = BNeq) }
  else if isPunct(peekToken(st), Lt)    { op = Some(value = BLt)  }
  else if isPunct(peekToken(st), LtEq)  { op = Some(value = BLte) }
  else if isPunct(peekToken(st), Gt)    { op = Some(value = BGt)  }
  else if isPunct(peekToken(st), GtEq)  { op = Some(value = BGte) }
  match op {
    case None -> lhs
    case Some(binop) -> {
      val _ = advance(st)
      val rhs = parseCoalesceExpr(st)
      // Detect chained comparison.
      var chainOp: Option[BinOp] = None
      if isPunct(peekToken(st), EqEq)  { chainOp = Some(value = BEq)  }
      else if isPunct(peekToken(st), NotEq) { chainOp = Some(value = BNeq) }
      else if isPunct(peekToken(st), Lt)    { chainOp = Some(value = BLt)  }
      else if isPunct(peekToken(st), LtEq)  { chainOp = Some(value = BLte) }
      else if isPunct(peekToken(st), Gt)    { chainOp = Some(value = BGt)  }
      else if isPunct(peekToken(st), GtEq)  { chainOp = Some(value = BGte) }
      match chainOp {
        case Some(_) -> {
          emitErr(st, "P0082", "comparison operators do not chain (use parentheses)", peekSpan(st))
        }
        case None -> {}
      }
      mkExpr(EBinop(op = binop, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    }
  }
}

func parseAndExpr(st: inout ParseState): Expr {
  var lhs = parseCompareExpr(st)
  var keep = true
  while keep {
    if isKw(peekToken(st), KwAnd) {
      val _ = advance(st)
      val rhs = parseCompareExpr(st)
      lhs = mkExpr(EBinop(op = BAnd, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else {
      keep = false
    }
  }
  lhs
}

// parseOrExpr: handles `or` and `xor` but NOT `implies`.
// Used by quantifier `where` clauses so they don't absorb the trailing
// `implies BODY`.
pub func parseOrExpr(st: inout ParseState): Expr {
  var lhs = parseAndExpr(st)
  var keep = true
  while keep {
    if isKw(peekToken(st), KwOr) {
      val _ = advance(st)
      val rhs = parseAndExpr(st)
      lhs = mkExpr(EBinop(op = BOr, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else if isKw(peekToken(st), KwXor) {
      val _ = advance(st)
      val rhs = parseAndExpr(st)
      lhs = mkExpr(EBinop(op = BXor, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
    } else {
      keep = false
    }
  }
  lhs
}

func parseImpliesExpr(st: inout ParseState): Expr {
  val lhs = parseOrExpr(st)
  if identStr(peekToken(st)) == "implies" {
    val _ = advance(st)
    val rhs = parseImpliesExpr(st)
    mkExpr(EBinop(op = BImplies, lhs = lhs, rhs = rhs), joinSpans(lhs.span, rhs.span))
  } else {
    lhs
  }
}

pub func parseExpr(st: inout ParseState): Expr {
  // Wrap each `parseExpr` invocation as an `SkExpr` node so the CST
  // mirrors the recursive structure of the AST.  Sub-expression
  // recursions (e.g. operands of a binary op) reach this same entry
  // point and produce nested `SkExpr` children.  The single internal
  // helper `parseImpliesExpr` is *not* wrapped — it's the precedence-
  // climbing seam, not a distinct expression node.
  cstStart(st, SkExpr)
  val e = parseImpliesExpr(st)
  cstFinish(st)
  e
}

// ─────────────────────────────────────────────────────────────────────────────
// Blocks and statements.
// ─────────────────────────────────────────────────────────────────────────────

pub func parseBlock(st: inout ParseState): Block {
  // Each `{ … }` block becomes an `SkBlock` CST node, regardless of
  // whether it's a function body, lambda body, or control-flow
  // body.  Children are the `{` token, statement nodes (each
  // `SkStatement`), `TStmtEnd` separators consumed inline, and the
  // `}` token.
  cstStart(st, SkBlock)
  val startSpan = peekSpan(st)
  val result = match tryEatPunct(st, LBrace) {
    case None -> {
      emitErr(st, "P0230", "expected '{' to start block", peekSpan(st))
      val emptyStmts: List[Statement] = newList()
      Block(statements = emptyStmts, span = startSpan)
    }
    case Some(_) -> {
      val _ = skipStmtEnds(st)
      val stmts: List[Statement] = newList()
      while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
        val before = mark(st)
        stmts.add(parseStatement(st))
        match peekToken(st) {
          case TStmtEnd -> {
            val _ = advance(st)
            val _ = skipStmtEnds(st)
          }
          case TPunct(p) -> {
            match p {
              case Semi -> {
                val _ = advance(st)
                val _ = skipStmtEnds(st)
              }
              case _ -> {}
            }
          }
          case _ -> {}
        }
        forceAdvanceIfStuck(st, before)
      }
      val endSpan = match tryEatPunct(st, RBrace) {
        case Some(t) -> t.span
        case None -> {
          emitErr(st, "P0231", "expected '}' to close block", peekSpan(st))
          startSpan
        }
      }
      Block(statements = stmts, span = joinSpans(startSpan, endSpan))
    }
  }
  cstFinish(st)
  result
}

pub func parseStatement(st: inout ParseState): Statement {
  // Wrap every statement as an `SkStatement` node.  Inner expression
  // / block / contract recursion produces nested CST nodes of the
  // matching kind.
  cstStart(st, SkStatement)
  val s = parseStatementInner(st)
  cstFinish(st)
  s
}

func parseStatementInner(st: inout ParseState): Statement {
  val startSpan = peekSpan(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwVal -> {
          val lb = parseLocalBinding(st)
          mkStmt(SLocal(binding = lb), joinSpans(startSpan, peekSpan(st)))
        }
        case KwVar -> {
          val lb = parseLocalBinding(st)
          mkStmt(SLocal(binding = lb), joinSpans(startSpan, peekSpan(st)))
        }
        case KwLet -> {
          val lb = parseLocalBinding(st)
          mkStmt(SLocal(binding = lb), joinSpans(startSpan, peekSpan(st)))
        }
        case KwReturn -> {
          val _ = advance(st)
          val value: Option[Expr] =
            match peekToken(st) {
              case TStmtEnd -> None
              case TPunct(p) -> {
                match p {
                  case RBrace -> None
                  case Semi -> None
                  case _ -> Some(value = parseExpr(st))
                }
              }
              case TEof -> None
              case _ -> Some(value = parseExpr(st))
            }
          val endSpan = match value { case Some(e) -> e.span; case None -> startSpan }
          mkStmt(SReturn(value = value), joinSpans(startSpan, endSpan))
        }
        case KwThrow -> {
          val _ = advance(st)
          val e = parseExpr(st)
          mkStmt(SThrow(expr = e), joinSpans(startSpan, e.span))
        }
        case KwTry -> {
          val _ = advance(st)
          val body = parseBlock(st)
          val catches: List[CatchClause] = newList()
          var keepGoing = true
          while keepGoing {
            if identStr(peekToken(st)) == "catch" {
              catches.add(parseCatchClause(st))
            } else {
              keepGoing = false
            }
          }
          val finally_ : Option[Block] =
            if identStr(peekToken(st)) == "finally" {
              val _ = advance(st)
              Some(parseBlock(st))
            } else {
              None
            }
          val endSpan =
            match finally_ {
              case Some(fb) -> fb.span
              case None ->
                if catches.count > 0 { catches[catches.count - 1].span } else { body.span }
            }
          mkStmt(STry(body = body, catches = catches, finally_ = finally_), joinSpans(startSpan, endSpan))
        }
        case KwDo -> {
          val _ = advance(st)
          val body = parseBlock(st)
          mkStmt(SLoop(label = None, body = body), joinSpans(startSpan, body.span))
        }
        case KwScope -> {
          val _ = advance(st)
          val body = parseBlock(st)
          mkStmt(SScope(binding = None, body = body), joinSpans(startSpan, body.span))
        }
        case KwFor -> {
          val _ = advance(st)
          val pat = parsePattern(st)
          match tryEatKw(st, KwIn) {
            case Some(_) -> {}
            case None -> {
              emitErr(st, "P0221", "expected 'in' in for-loop", peekSpan(st))
            }
          }
          // The iterator may be a plain collection expression (`for x in xs`)
          // or a range (`for i in lo .. hi` / `lo ..= hi` / `lo ..< hi`).
          // `parseExpr` stops at the range operator, so check for one here and
          // wrap the bounds in an `ERange` (#1478).  `..` / `..<` are half-open
          // (hi excluded); `..=` is closed.
          val iterLo = parseExpr(st)
          val iter =
            if isPunct(peekToken(st), DotDotEq) {
              val _ = advance(st)
              val hi = parseExpr(st)
              mkExpr(ERange(bound = RBClosed(lo = iterLo, hi = hi)),
                     joinSpans(iterLo.span, hi.span))
            } else if isPunct(peekToken(st), DotDotLt) {
              val _ = advance(st)
              val hi = parseExpr(st)
              mkExpr(ERange(bound = RBHalfOpen(lo = iterLo, hi = hi)),
                     joinSpans(iterLo.span, hi.span))
            } else if isPunct(peekToken(st), DotDot) {
              val _ = advance(st)
              val hi = parseExpr(st)
              mkExpr(ERange(bound = RBHalfOpen(lo = iterLo, hi = hi)),
                     joinSpans(iterLo.span, hi.span))
            } else {
              iterLo
            }
          val invs = parseLoopInvariants(st)
          val rawBody = parseBlock(st)
          val body = prependLoopInvariants(invs, rawBody)
          mkStmt(SFor(label = None, pat = pat, iter = iter, body = body),
                 joinSpans(startSpan, body.span))
        }
        case KwWhile -> {
          val _ = advance(st)
          val cond = parseExpr(st)
          val invs = parseLoopInvariants(st)
          val rawBody = parseBlock(st)
          val body = prependLoopInvariants(invs, rawBody)
          mkStmt(SWhile(label = None, cond = cond, body = body),
                 joinSpans(startSpan, body.span))
        }
        case _ -> {
          parseExprStatement(st, startSpan)
        }
      }
    }
    case TIdent(name) -> {
      if name == "break" {
        val _ = advance(st)
        val label: Option[String] =
          match tryEatIdent(st) {
            case Some(ns) -> Some(value = ns.name)
            case None -> None
          }
        mkStmt(SBreak(label = label), joinSpans(startSpan, peekSpan(st)))
      } else if name == "continue" {
        val _ = advance(st)
        val label: Option[String] =
          match tryEatIdent(st) {
            case Some(ns) -> Some(value = ns.name)
            case None -> None
          }
        mkStmt(SContinue(label = label), joinSpans(startSpan, peekSpan(st)))
      } else if name == "defer" {
        val _ = advance(st)
        val body = parseBlock(st)
        mkStmt(SDefer(body = body), joinSpans(startSpan, body.span))
      } else {
        parseExprStatement(st, startSpan)
      }
    }
    case _ -> parseExprStatement(st, startSpan)
  }
}

func parseExprStatement(st: inout ParseState, startSpan: in Span): Statement {
  val e = parseExpr(st)
  // Distinguish: assignment, stub-builder rule (`->`), or plain expression.
  if isPunct(peekToken(st), Eq) or isPunct(peekToken(st), PlusEq)
     or isPunct(peekToken(st), MinusEq) or isPunct(peekToken(st), StarEq)
     or isPunct(peekToken(st), SlashEq) or isPunct(peekToken(st), PercentEq) {
    var assignOp = AssEq
    match peekToken(st) {
      case TPunct(p) -> {
        match p {
          case Eq        -> { assignOp = AssEq }
          case PlusEq    -> { assignOp = AssPlus }
          case MinusEq   -> { assignOp = AssMinus }
          case StarEq    -> { assignOp = AssStar }
          case SlashEq   -> { assignOp = AssSlash }
          case PercentEq -> { assignOp = AssPercent }
          case _ -> {}
        }
      }
      case _ -> {}
    }
    val _ = advance(st)
    val value = parseExpr(st)
    mkStmt(SAssign(target = e, op = assignOp, value = value),
           joinSpans(startSpan, value.span))
  } else if isPunct(peekToken(st), Arrow) {
    val _ = advance(st)
    val rhs = parseExpr(st)
    mkStmt(SRule(lhs = e, rhs = rhs), joinSpans(startSpan, rhs.span))
  } else {
    mkStmt(SExpr(expr = e), joinSpans(startSpan, e.span))
  }
}

pub func parseLocalBinding(st: inout ParseState): LocalBinding {
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwVal -> {
          val _ = advance(st)
          val pat = parsePattern(st)
          val ty: Option[TypeExpr] =
            if isPunct(peekToken(st), Colon) {
              val _ = advance(st)
              Some(value = parseTypeExpr(st))
            } else { None }
          match tryEatPunct(st, Eq) {
            case Some(_) -> {}
            case None -> {
              emitErr(st, "P0210", "expected '=' in 'val' binding", peekSpan(st))
            }
          }
          val init = parseExpr(st)
          LBVal(pat = pat, ty = ty, init = init)
        }
        case KwVar -> {
          val _ = advance(st)
          val ns = readIdent(st, "var binding")
          val ty: Option[TypeExpr] =
            if isPunct(peekToken(st), Colon) {
              val _ = advance(st)
              Some(value = parseTypeExpr(st))
            } else { None }
          val init: Option[Expr] =
            if isPunct(peekToken(st), Eq) {
              val _ = advance(st)
              Some(value = parseExpr(st))
            } else { None }
          LBVar(name = ns.name, ty = ty, init = init)
        }
        case KwLet -> {
          val _ = advance(st)
          val ns = readIdent(st, "let binding")
          val ty: Option[TypeExpr] =
            if isPunct(peekToken(st), Colon) {
              val _ = advance(st)
              Some(value = parseTypeExpr(st))
            } else { None }
          match tryEatPunct(st, Eq) {
            case Some(_) -> {}
            case None -> {
              emitErr(st, "P0211", "expected '=' in 'let' binding", peekSpan(st))
            }
          }
          val init = parseExpr(st)
          LBLet(name = ns.name, ty = ty, init = init)
        }
        case _ -> {
          emitErr(st, "P0212", "expected 'val', 'var', or 'let'", peekSpan(st))
          val sp = peekSpan(st)
          val errPat = mkPat(PError, sp)
          val errExpr = mkExpr(EError, sp)
          LBVal(pat = errPat, ty = None, init = errExpr)
        }
      }
    }
    case _ -> {
      emitErr(st, "P0212", "expected 'val', 'var', or 'let'", peekSpan(st))
      val sp = peekSpan(st)
      val errPat = mkPat(PError, sp)
      val errExpr = mkExpr(EError, sp)
      LBVal(pat = errPat, ty = None, init = errExpr)
    }
  }
}

func parseCatchClause(st: inout ParseState): CatchClause {
  val startTok = advance(st)  // 'catch'
  val ns = readIdent(st, "catch type")
  val bindName: Option[String] =
    if isKw(peekToken(st), KwAs) {
      val _ = advance(st)
      match tryEatIdent(st) {
        case Some(n) -> Some(value = n.name)
        case None -> {
          emitErr(st, "P0220", "expected identifier after 'as' in catch", peekSpan(st))
          None
        }
      }
    } else {
      None
    }
  val body = parseBlock(st)
  CatchClause(typeName = ns.name, bindName = bindName, body = body,
              span = joinSpans(startTok.span, body.span))
}

// isPunct for TStmtEnd — small helper used in parseMatchExpr above.
func isPunctOrStmtEnd(tok: in Token, p: in Punct): Bool {
  match tok {
    case TStmtEnd -> false
    case TPunct(q) -> q == p
    case _ -> false
  }
}
