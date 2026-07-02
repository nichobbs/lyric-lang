//! parser_items.l — item body parsers and top-level parse entry point.
//! Mirrors P5b–P8 of compiler/src/Lyric.Parser/Parser.fs.
package Lyric.Parser

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// Skip helper (error recovery).
// ─────────────────────────────────────────────────────────────────────────────
func skipItemBody(st: inout ParseState): Span {
  val startSpan = peekSpan(st)
  var depth = 0
  var seenBrace = false
  var keepGoing = true
  var lastSpan = startSpan
  while keepGoing and not isAtEnd(st) {
    val tok = peek(st)
    lastSpan = tok.span
    match tok.token {
      case TPunct(p) -> {
        match p {
          case LBrace -> {
            seenBrace = true
            depth = depth + 1
            val _ = advance(st)
          }
          case LParen -> {
            depth = depth + 1
            val _ = advance(st)
          }
          case LBracket -> {
            depth = depth + 1
            val _ = advance(st)
          }
          case RBrace -> {
            if depth > 0 {
              depth = depth - 1
            }
            val _ = advance(st)
            if seenBrace and depth == 0 {
              keepGoing = false
            }
          }
          case RParen -> {
            if depth > 0 {
              depth = depth - 1
            }
            val _ = advance(st)
          }
          case RBracket -> {
            if depth > 0 {
              depth = depth - 1
            }
            val _ = advance(st)
          }
          case _ -> {
            val _ = advance(st)
          }
        }
      }
      case TStmtEnd -> {
        if depth == 0 {
          keepGoing = false
        } else {
          val _ = advance(st)
        }
      }
      case _ -> {
        val _ = advance(st)
      }
    }
  }
  joinSpans(startSpan, lastSpan)
}

// ─────────────────────────────────────────────────────────────────────────────
// P5b helpers: field decl, type-alias, distinct-type, record, union, enum,
// opaque type.
// ─────────────────────────────────────────────────────────────────────────────
func parseFieldDecl(st: inout ParseState): FieldDecl {
  val startSpan = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  val vis = match tryEatKw(st, KwPub) {
    case Some(t) -> Some(VisPub(span = t.span))
    case None -> {
      match tryEatKw(st, KwInternal) {
        case Some(t) -> Some(VisInternal(span = t.span))
        case None -> None
      }
    }
  }
  // A field may be prefixed with `var` to mark it mutable (language
  // reference §3.4).  Visibility precedes the `var` marker.
  val isMut = match tryEatKw(st, KwVar) { case Some(_) -> true; case None -> false }
  val ns = readIdent(st, "field")
  match tryEatPunct(st, Colon) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0120", "expected ':' after field name", peekSpan(st))
    }
  }
  val ty = parseTypeExpr(st)
  val dflt = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseExpr(st)); case None -> None }
  val trailingAnns = parseSameLineTrailingAnnotations(st)
  val allAnns = listConcat(anns, trailingAnns)
  val endSpan = match dflt { case Some(e) -> e.span; case None -> ty.span }
  FieldDecl(
    docComments = docs,
    annotations = allAnns,
    visibility = vis,
    isMutable = isMut,
    name = ns.name,
    ty = ty,
    dflt = dflt,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseTypeAliasBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): TypeAliasDecl {
  val startTok = advance(st)
  // 'alias'
  val ns = readIdent(st, "alias")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0110", "expected '=' in type alias", peekSpan(st))
    }
  }
  val rhs = parseTypeExpr(st)
  TypeAliasDecl(name = ns.name, generics = generics, rhs = rhs, span = joinSpans(startTok.span, rhs.span))
}

func parseDerivesClauseOpt(st: inout ParseState): List[String] {
  val xs: List[String] = newList()
  if identStr(peekToken(st)) == "derives" {
    val _ = advance(st)
    match tryEatIdent(st) {
      case Some(ns) -> {
        xs.add(ns.name)
      }
      case None -> {
        emitErr(st, "P0111", "expected a marker name in 'derives' clause", peekSpan(st))
      }
    }
    while isPunct(peekToken(st), Comma) {
      val _ = advance(st)
      match tryEatIdent(st) {
        case Some(ns) -> {
          xs.add(ns.name)
        }
        case None -> {
          emitErr(st, "P0111", "expected a marker name in 'derives' clause", peekSpan(st))
        }
      }
    }
  }
  xs
}

func parseDistinctTypeBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): DistinctTypeDecl {
  val startTok = advance(st)
  // 'type'
  val ns = readIdent(st, "type")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0112", "expected '=' in distinct type declaration", peekSpan(st))
    }
  }
  val initial = parseTypeExpr(st)
  // Unwrap TRefined back into head + bound for distinct-type context.
  var underlying = initial
  var rangeOpt: Option[RangeBound] = None
  match initial.kind {
    case TRefined(path, bound) -> {
      underlying = mkType(TRef(path = path), path.span)
      rangeOpt = Some(bound)
    }
    case _ -> {
    }
  }
  if rangeOpt == None {
    if identStr(peekToken(st)) == "range" {
      val _ = advance(st)
      rangeOpt = Some(parseRangeBound(st))
    }
  }
  val derives = parseDerivesClauseOpt(st)
  val endSpan = lastSpan(st)
  DistinctTypeDecl(
    name = ns.name,
    generics = generics,
    underlying = underlying,
    rangeClause = rangeOpt,
    derives = derives,
    span = joinSpans(startTok.span, endSpan)
  )
}

func injectSelfIfNeeded(fn: in FunctionDecl): FunctionDecl {
  if fn.params.count > 0 and fn.params[0].name == "self" {
    return fn
  }
  val newParams: List[Param] = newList()
  val selfParam = Param(
    mode = PMIn,
    modeExplicit = false,
    name = "self",
    ty = mkType(TSelf, syntheticSpan()),
    dflt = None,
    annotations = newList(),
    span = syntheticSpan()
  )
  newParams.add(selfParam)
  var i = 0
  while i < fn.params.count {
    newParams.add(fn.params[i])
    i = i + 1
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = newParams,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
}

func parseRecordMembers(st: inout ParseState): List[RecordMember] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0121", "expected '{' to start record body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[RecordMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    match peekToken(st) {
      case TKeyword(k) -> {
        match k {
          case KwInvariant -> {
            xs.add(RMInvariant(inv = parseInvariantClause(st)))
          }
          case KwFunc -> {
            val fn = parseFunctionDeclBody(st, None)
            xs.add(RMFunc(fn = injectSelfIfNeeded(fn)))
          }
          case KwAsync -> {
            val next1 = peekAt(st, 1)
            match next1.token {
              case TKeyword(k2) -> {
                match k2 {
                  case KwFunc -> {
                    val fn = parseFunctionDeclBody(st, None)
                    xs.add(RMFunc(fn = injectSelfIfNeeded(fn)))
                  }
                  case _ -> {
                    xs.add(RMField(field = parseFieldDecl(st)))
                  }
                }
              }
              case _ -> {
                xs.add(RMField(field = parseFieldDecl(st)))
              }
            }
          }
          case _ -> {
            xs.add(RMField(field = parseFieldDecl(st)))
          }
        }
      }
      case _ -> {
        xs.add(RMField(field = parseFieldDecl(st)))
      }
    }
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0122", "expected '}' to close record body", peekSpan(st))
    }
  }
  xs
}

func parseRecordBody(st: inout ParseState, genericsPrefix: Option[GenericParams], isExposed: Bool): RecordDecl {
  val startSpan = peekSpan(st)
  if isExposed {
    val _ = advance(st)
  }
  // 'exposed'
  val _ = advance(st)
  // 'record'
  val ns = readIdent(st, "record")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  val members = parseRecordMembers(st)
  val endSpan = lastSpan(st)
  RecordDecl(
    name = ns.name,
    generics = generics,
    whereClause = whereClause,
    members = members,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseUnionField(st: inout ParseState): UnionField {
  val saved = mark(st)
  match peekToken(st) {
    case TIdent(_) -> {
      val nameTok = advance(st)
      if isPunct(peekToken(st), Colon) {
        val _ = advance(st)
        val ty = parseTypeExpr(st)
        val fieldName = identStr(nameTok.token)
        UFNamed(name = fieldName, ty = ty, span = joinSpans(nameTok.span, ty.span))
      } else {
        reset(st, saved)
        val ty = parseTypeExpr(st)
        UFPos(ty = ty, span = ty.span)
      }
    }
    case _ -> {
      val ty = parseTypeExpr(st)
      UFPos(ty = ty, span = ty.span)
    }
  }
}

func parseUnionCase(st: inout ParseState): UnionCase {
  val startSpan = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  match tryEatKw(st, KwCase) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0130", "expected 'case' to start a union case", peekSpan(st))
    }
  }
  val ns = readIdent(st, "case")
  val fields: List[UnionField] = newList()
  if isPunct(peekToken(st), LParen) {
    val _ = advance(st)
    if not isPunct(peekToken(st), RParen) {
      fields.add(parseUnionField(st))
      while isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RParen) {
          fields.add(parseUnionField(st))
        }
      }
    }
    match tryEatPunct(st, RParen) {
      case Some(_) -> {
      }
      case None -> {
        emitErr(st, "P0131", "expected ')' to close union case payload", peekSpan(st))
      }
    }
  }
  val endSpan = lastSpan(st)
  UnionCase(
    docComments = docs,
    annotations = anns,
    name = ns.name,
    fields = fields,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseUnionCases(st: inout ParseState): List[UnionCase] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0132", "expected '{' to start union body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[UnionCase] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    xs.add(parseUnionCase(st))
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0133", "expected '}' to close union body", peekSpan(st))
    }
  }
  xs
}

func parseUnionBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): UnionDecl {
  val startTok = advance(st)
  // 'union'
  val ns = readIdent(st, "union")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  val cases = parseUnionCases(st)
  val endSpan = lastSpan(st)
  UnionDecl(
    name = ns.name,
    generics = generics,
    whereClause = whereClause,
    cases = cases,
    span = joinSpans(startTok.span, endSpan)
  )
}

func parseEnumCase(st: inout ParseState): EnumCase {
  val startSpan = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  match tryEatKw(st, KwCase) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0140", "expected 'case' to start an enum case", peekSpan(st))
    }
  }
  val ns = readIdent(st, "case")
  EnumCase(docComments = docs, annotations = anns, name = ns.name, span = joinSpans(startSpan, ns.span))
}

func parseEnumCases(st: inout ParseState): List[EnumCase] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0141", "expected '{' to start enum body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[EnumCase] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    xs.add(parseEnumCase(st))
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0142", "expected '}' to close enum body", peekSpan(st))
    }
  }
  xs
}

func parseEnumBody(st: inout ParseState): EnumDecl {
  val startTok = advance(st)
  // 'enum'
  val ns = readIdent(st, "enum")
  val cases = parseEnumCases(st)
  val endSpan = lastSpan(st)
  EnumDecl(name = ns.name, cases = cases, span = joinSpans(startTok.span, endSpan))
}

func parseOpaqueMembers(st: inout ParseState): List[OpaqueMember] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0150", "expected '{' to start opaque type body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[OpaqueMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    match peekToken(st) {
      case TKeyword(k) -> {
        match k {
          case KwInvariant -> {
            xs.add(OMInvariant(inv = parseInvariantClause(st)))
          }
          case _ -> {
            xs.add(OMField(field = parseFieldDecl(st)))
          }
        }
      }
      case _ -> {
        xs.add(OMField(field = parseFieldDecl(st)))
      }
    }
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0151", "expected '}' to close opaque type body", peekSpan(st))
    }
  }
  xs
}

func parseOpaqueTypeBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): OpaqueTypeDecl {
  val startTok = peek(st)
  match tryEatKw(st, KwOpaque) {
    case Some(_) -> {
    }
    case None -> {
    }
  }
  match tryEatKw(st, KwType) {
    case Some(_) -> {
    }
    case None -> {
    }
  }
  val ns = readIdent(st, "opaque type")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val postAnns = parseTrailingAnnotations(st)
  var hasBody = false
  var members: List[OpaqueMember] = newList()
  match peekToken(st) {
    case TPunct(p) -> {
      match p {
        case LBrace -> {
          hasBody = true
          members = parseOpaqueMembers(st)
        }
        case Eq -> {
          val _ = advance(st)
          match tryEatKw(st, KwRecord) {
            case Some(_) -> {
            }
            case None -> {
            }
          }
          hasBody = true
          members = parseOpaqueMembers(st)
        }
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val endSpan = lastSpan(st)
  OpaqueTypeDecl(
    name = ns.name,
    generics = generics,
    whereClause = whereClause,
    annotations = postAnns,
    members = members,
    hasBody = hasBody,
    span = joinSpans(startTok.span, endSpan)
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// P6a: parameters, contract clauses, function body, function decl.
// ─────────────────────────────────────────────────────────────────────────────
func parseParam(st: inout ParseState): Param {
  val startSpan = peekSpan(st)
  // Leading annotations precede the parameter name (e.g. `@body req: T`).
  val anns = parseItemAnnotations(st)
  val paramName = match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwSelf -> {
          val _ = advance(st)
          "self"
        }
        case _ -> {
          val ns = readIdent(st, "parameter")
          ns.name
        }
      }
    }
    case _ -> {
      val ns = readIdent(st, "parameter")
      ns.name
    }
  }
  match tryEatPunct(st, Colon) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0161", "expected ':' after parameter name", peekSpan(st))
    }
  }
  // `modeExplicit` records whether the source actually wrote a mode
  // keyword.  Omitting it is sugar for `in`, but the formatter must not
  // synthesise an `in` the author never typed, so we keep the distinction.
  val modeExplicit = match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwIn -> true
        case KwOut -> true
        case KwInout -> true
        case _ -> false
      }
    }
    case _ -> false
  }
  val mode = match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwIn -> {
          val _ = advance(st)
          PMIn
        }
        case KwOut -> {
          val _ = advance(st)
          PMOut
        }
        case KwInout -> {
          val _ = advance(st)
          PMInout
        }
        case _ -> PMIn
      }
    }
    case _ -> PMIn
  }
  val ty = parseTypeExpr(st)
  val dflt = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseExpr(st)); case None -> None }
  val endSpan = match dflt { case Some(e) -> e.span; case None -> ty.span }
  Param(
    mode = mode,
    modeExplicit = modeExplicit,
    name = paramName,
    ty = ty,
    dflt = dflt,
    annotations = anns,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseParamList(st: inout ParseState): List[Param] {
  match tryEatPunct(st, LParen) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0162", "expected '(' to start parameter list", peekSpan(st))
    }
  }
  val xs: List[Param] = newList()
  if not isPunct(peekToken(st), RParen) {
    xs.add(parseParam(st))
    while isPunct(peekToken(st), Comma) {
      val _ = advance(st)
      if not isPunct(peekToken(st), RParen) {
        xs.add(parseParam(st))
      }
    }
  }
  match tryEatPunct(st, RParen) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0163", "expected ')' to close parameter list", peekSpan(st))
    }
  }
  xs
}

@pure
func isContractKeyword(k: in Keyword): Bool {
  match k {
    case KwRequires -> true
    case KwEnsures -> true
    case KwWhen -> true
    case _ -> false
  }
}

func parseContractClauseOpt(st: inout ParseState): Option[ContractClause] {
  // Peek before opening the CST node — only emit `SkContractClause`
  // when we know we're committing to a clause; otherwise leave the
  // event log untouched.
  val isClause = match peekToken(st) { case TKeyword(k) -> isContractKeyword(k); case _ -> false }
  if not isClause {
    return None
  }
  cstStart(st, SkContractClause)
  val r = parseContractClauseOptInner(st)
  cstFinish(st)
  r
}

func parseContractClauseOptInner(st: inout ParseState): Option[ContractClause] {
  val startSpan = peekSpan(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwRequires -> {
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0170", "expected ':' after 'requires'", peekSpan(st))
            }
          }
          val e = parseExpr(st)
          Some(CCRequires(expr = e, span = joinSpans(startSpan, e.span)))
        }
        case KwEnsures -> {
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0170", "expected ':' after 'ensures'", peekSpan(st))
            }
          }
          val e = parseExpr(st)
          Some(CCEnsures(expr = e, span = joinSpans(startSpan, e.span)))
        }
        case KwWhen -> {
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0170", "expected ':' after 'when'", peekSpan(st))
            }
          }
          val e = parseExpr(st)
          Some(CCWhen(expr = e, span = joinSpans(startSpan, e.span)))
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

func parseContractClauses(st: inout ParseState): List[ContractClause] {
  val xs: List[ContractClause] = newList()
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    match parseContractClauseOpt(st) {
      case Some(c) -> {
        xs.add(c)
      }
      case None -> {
        keepGoing = false
      }
    }
  }
  xs
}

func parseFunctionBody(st: inout ParseState): FunctionBody {
  match peekToken(st) {
    case TPunct(p) -> {
      match p {
        case Eq -> {
          val _ = advance(st)
          FBExpr(expr = parseExpr(st))
        }
        case LBrace -> {
          FBBlock(block = parseBlock(st))
        }
        case _ -> {
          emitErr(st, "P0172", "expected '=' or '{' to start function body", peekSpan(st))
          val sp = peekSpan(st)
          FBBlock(block = Block(statements = newList(), span = sp))
        }
      }
    }
    case _ -> {
      emitErr(st, "P0172", "expected '=' or '{' to start function body", peekSpan(st))
      val sp = peekSpan(st)
      FBBlock(block = Block(statements = newList(), span = sp))
    }
  }
}

func parseFunctionDeclBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): FunctionDecl {
  val startSpan = peekSpan(st)
  val isAsync = match tryEatKw(st, KwAsync) { case Some(_) -> true; case None -> false }
  match tryEatKw(st, KwFunc) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0173", "expected 'func' keyword", peekSpan(st))
    }
  }
  val firstNs = readIdent(st, "function")
  val parts: List[String] = newList()
  parts.add(firstNs.name)
  while isPunct(peekToken(st), Dot) {
    val _ = advance(st)
    match tryEatIdent(st) {
      case Some(ns) -> {
        parts.add(ns.name)
      }
      case None -> {
      }
    }
  }
  var funcName = parts[0]
  var i = 1
  while i < parts.count {
    funcName = funcName + "." + parts[i]
    i = i + 1
  }
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val parameters = parseParamList(st)
  val _ = skipStmtEnds(st)
  val returnType = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  val contracts = parseContractClauses(st)
  val body = match peekToken(st) {
    case TPunct(p) -> {
      match p {
        case Eq -> Some(parseFunctionBody(st))
        case LBrace -> Some(parseFunctionBody(st))
        case _ -> None
      }
    }
    case _ -> None
  }
  val emptyDocs: List[DocComment] = newList()
  val emptyAnns: List[Annotation] = newList()
  val endSpan = lastSpan(st)
  FunctionDecl(
    docComments = emptyDocs,
    annotations = emptyAnns,
    visibility = None,
    isAsync = isAsync,
    name = funcName,
    generics = generics,
    params = parameters,
    ret = returnType,
    whereClause = whereClause,
    contracts = contracts,
    body = body,
    span = joinSpans(startSpan, endSpan)
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// P6b: interface and impl.
// ─────────────────────────────────────────────────────────────────────────────
func parseAssociatedTypeDecl(st: inout ParseState): AssociatedTypeDecl {
  val startTok = advance(st)
  // 'type'
  val ns = readIdent(st, "associated type")
  val dflt = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  val endSpan = match dflt { case Some(t) -> t.span; case None -> ns.span }
  AssociatedTypeDecl(name = ns.name, dflt = dflt, span = joinSpans(startTok.span, endSpan))
}

func parseInterfaceMemberOpt(st: inout ParseState): Option[InterfaceMember] {
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwType -> {
          Some(IMAssoc(assoc = parseAssociatedTypeDecl(st)))
        }
        case KwFunc -> {
          val fn0 = parseFunctionDeclBody(st, None)
          val fn = FunctionDecl(
            docComments = docs,
            annotations = anns,
            visibility = fn0.visibility,
            isAsync = fn0.isAsync,
            name = fn0.name,
            generics = fn0.generics,
            params = fn0.params,
            ret = fn0.ret,
            whereClause = fn0.whereClause,
            contracts = fn0.contracts,
            body = fn0.body,
            span = fn0.span
          )
          match fn.body {
            case None -> {
              Some(
                IMSig(
                  sig = FunctionSig(
                    docComments = fn.docComments,
                    isAsync = fn.isAsync,
                    name = fn.name,
                    generics = fn.generics,
                    params = fn.params,
                    ret = fn.ret,
                    whereClause = fn.whereClause,
                    contracts = fn.contracts,
                    span = fn.span
                  )
                )
              )
            }
            case Some(_) -> {
              Some(IMFunc(fn = fn))
            }
          }
        }
        case KwAsync -> {
          val fn0 = parseFunctionDeclBody(st, None)
          val fn = FunctionDecl(
            docComments = docs,
            annotations = anns,
            visibility = fn0.visibility,
            isAsync = fn0.isAsync,
            name = fn0.name,
            generics = fn0.generics,
            params = fn0.params,
            ret = fn0.ret,
            whereClause = fn0.whereClause,
            contracts = fn0.contracts,
            body = fn0.body,
            span = fn0.span
          )
          match fn.body {
            case None -> {
              Some(
                IMSig(
                  sig = FunctionSig(
                    docComments = fn.docComments,
                    isAsync = fn.isAsync,
                    name = fn.name,
                    generics = fn.generics,
                    params = fn.params,
                    ret = fn.ret,
                    whereClause = fn.whereClause,
                    contracts = fn.contracts,
                    span = fn.span
                  )
                )
              )
            }
            case Some(_) -> {
              Some(IMFunc(fn = fn))
            }
          }
        }
        case _ -> {
          emitErr(st, "P0181", "expected 'func', 'async func', or 'type' inside interface body", peekSpan(st))
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          None
        }
      }
    }
    case _ -> {
      emitErr(st, "P0181", "expected 'func', 'async func', or 'type' inside interface body", peekSpan(st))
      if not isAtEnd(st) {
        val _ = advance(st)
      }
      None
    }
  }
}

func parseInterfaceMembers(st: inout ParseState): List[InterfaceMember] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0182", "expected '{' to start interface body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[InterfaceMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    match parseInterfaceMemberOpt(st) {
      case Some(m) -> {
        xs.add(m)
      }
      case None -> {
      }
    }
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0183", "expected '}' to close interface body", peekSpan(st))
    }
  }
  xs
}

func parseInterfaceBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): InterfaceDecl {
  val startTok = advance(st)
  // 'interface'
  val ns = readIdent(st, "interface")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  val members = parseInterfaceMembers(st)
  val endSpan = lastSpan(st)
  InterfaceDecl(
    name = ns.name,
    generics = generics,
    whereClause = whereClause,
    members = members,
    span = joinSpans(startTok.span, endSpan)
  )
}

// Unlike `parseRecordMembers` (which runs `injectSelfIfNeeded` on every
// `RMFunc`), `impl` block methods here are intentionally left without an
// injected `self` param.  The two paths lower through different codegen:
// `lowerRecordMethod` (JVM) strips a leading self param via
// `stripLeadingSelfParam` before treating the rest of `fn.params` as real
// parameters — `injectSelfIfNeeded` guarantees that param exists so the
// strip has something to remove.  `lowerImplMethod` / `lowerImplMethodMsil`
// take `fn.params` as-is and *always* reserve receiver slot 0 implicitly,
// independent of `fn.params`'s contents (the `self` keyword parses to the
// dedicated `ESelf` AST node, which always compiles straight to `ldarg.0` —
// never a named-parameter lookup).  Injecting a synthetic self param here
// would add a real, un-stripped extra entry to `fn.params` that neither
// impl codegen path expects, silently shifting every declared parameter's
// slot by one.  Do not add `injectSelfIfNeeded` to this function without
// also updating `lowerImplMethod` (JVM) and `lowerImplMethodMsil` (MSIL)
// to strip it first.
func parseImplMemberOpt(st: inout ParseState): Option[ImplMember] {
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwType -> {
          Some(IMplAssoc(assoc = parseAssociatedTypeDecl(st)))
        }
        case KwFunc -> {
          val fn0 = parseFunctionDeclBody(st, None)
          val fn = FunctionDecl(
            docComments = docs,
            annotations = anns,
            visibility = fn0.visibility,
            isAsync = fn0.isAsync,
            name = fn0.name,
            generics = fn0.generics,
            params = fn0.params,
            ret = fn0.ret,
            whereClause = fn0.whereClause,
            contracts = fn0.contracts,
            body = fn0.body,
            span = fn0.span
          )
          Some(IMplFunc(fn = fn))
        }
        case KwAsync -> {
          val fn0 = parseFunctionDeclBody(st, None)
          val fn = FunctionDecl(
            docComments = docs,
            annotations = anns,
            visibility = fn0.visibility,
            isAsync = fn0.isAsync,
            name = fn0.name,
            generics = fn0.generics,
            params = fn0.params,
            ret = fn0.ret,
            whereClause = fn0.whereClause,
            contracts = fn0.contracts,
            body = fn0.body,
            span = fn0.span
          )
          Some(IMplFunc(fn = fn))
        }
        case _ -> {
          emitErr(st, "P0184", "expected 'func', 'async func', or 'type' inside impl body", peekSpan(st))
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          None
        }
      }
    }
    case _ -> {
      emitErr(st, "P0184", "expected 'func', 'async func', or 'type' inside impl body", peekSpan(st))
      if not isAtEnd(st) {
        val _ = advance(st)
      }
      None
    }
  }
}

func parseImplMembers(st: inout ParseState): List[ImplMember] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0185", "expected '{' to start impl body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[ImplMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    match parseImplMemberOpt(st) {
      case Some(m) -> {
        xs.add(m)
      }
      case None -> {
      }
    }
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0186", "expected '}' to close impl body", peekSpan(st))
    }
  }
  xs
}

func parseImplBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): ImplDecl {
  val startTok = advance(st)
  // 'impl'
  val suffixGenerics = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, suffixGenerics)
  val iface = parseConstraintRef(st)
  match tryEatKw(st, KwFor) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0180", "expected 'for' in impl declaration", peekSpan(st))
    }
  }
  val target = parseTypeExpr(st)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  val members = parseImplMembers(st)
  val endSpan = lastSpan(st)
  ImplDecl(
    generics = generics,
    iface = iface,
    target = target,
    whereClause = whereClause,
    members = members,
    span = joinSpans(startTok.span, endSpan)
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// P8: remaining item kinds.
// ─────────────────────────────────────────────────────────────────────────────
func parseEntryDecl(st: inout ParseState): EntryDecl {
  val startSpan = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  val vis = match tryEatKw(st, KwPub) {
    case Some(t) -> Some(VisPub(span = t.span))
    case None -> {
      match tryEatKw(st, KwInternal) {
        case Some(t) -> Some(VisInternal(span = t.span))
        case None -> None
      }
    }
  }
  val _ = advance(st)
  // 'entry'
  val ns = readIdent(st, "entry")
  val parameters = parseParamList(st)
  val returnType = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  val contracts = parseContractClauses(st)
  val body = parseFunctionBody(st)
  val endSpan = lastSpan(st)
  EntryDecl(
    docComments = docs,
    annotations = anns,
    visibility = vis,
    name = ns.name,
    params = parameters,
    ret = returnType,
    contracts = contracts,
    body = body,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseProtectedField(st: inout ParseState): ProtectedField {
  val startSpan = peekSpan(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwVar -> {
          val _ = advance(st)
          val ns = readIdent(st, "field")
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0240", "expected ':' after field name", peekSpan(st))
            }
          }
          val ty = parseTypeExpr(st)
          val init = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseExpr(st)); case None -> None }
          val endSpan = match init { case Some(e) -> e.span; case None -> ty.span }
          PFVar(name = ns.name, ty = ty, init = init, span = joinSpans(startSpan, endSpan))
        }
        case KwLet -> {
          val _ = advance(st)
          val ns = readIdent(st, "field")
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0240", "expected ':' after field name", peekSpan(st))
            }
          }
          val ty = parseTypeExpr(st)
          val init = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseExpr(st)); case None -> None }
          var endSpan = ty.span
          match init {
            case Some(e) -> {
              endSpan = e.span
            }
            case None -> {
            }
          }
          PFLet(name = ns.name, ty = ty, init = init, span = joinSpans(startSpan, endSpan))
        }
        case _ -> {
          PFImmutable(field = parseFieldDecl(st))
        }
      }
    }
    case _ -> {
      PFImmutable(field = parseFieldDecl(st))
    }
  }
}

func parseProtectedMember(st: inout ParseState): ProtectedMember {
  val _ = skipStmtEnds(st)
  match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwInvariant -> {
          PMInvariant(inv = parseInvariantClause(st))
        }
        case KwEntry -> {
          PMEntry(entryDecl = parseEntryDecl(st))
        }
        case KwPub -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwEntry -> {
                  PMEntry(entryDecl = parseEntryDecl(st))
                }
                case KwFunc -> {
                  val docs = parseItemDocComments(st)
                  val anns = parseItemAnnotations(st)
                  val visTok = advance(st)
                  // pub
                  val fn0 = parseFunctionDeclBody(st, None)
                  val fn = FunctionDecl(
                    docComments = docs,
                    annotations = anns,
                    visibility = Some(VisPub(span = visTok.span)),
                    isAsync = fn0.isAsync,
                    name = fn0.name,
                    generics = fn0.generics,
                    params = fn0.params,
                    ret = fn0.ret,
                    whereClause = fn0.whereClause,
                    contracts = fn0.contracts,
                    body = fn0.body,
                    span = fn0.span
                  )
                  PMFunc(fn = fn)
                }
                case KwAsync -> {
                  val docs = parseItemDocComments(st)
                  val anns = parseItemAnnotations(st)
                  val visTok = advance(st)
                  // pub
                  val fn0 = parseFunctionDeclBody(st, None)
                  val fn = FunctionDecl(
                    docComments = docs,
                    annotations = anns,
                    visibility = Some(VisPub(span = visTok.span)),
                    isAsync = fn0.isAsync,
                    name = fn0.name,
                    generics = fn0.generics,
                    params = fn0.params,
                    ret = fn0.ret,
                    whereClause = fn0.whereClause,
                    contracts = fn0.contracts,
                    body = fn0.body,
                    span = fn0.span
                  )
                  PMFunc(fn = fn)
                }
                case _ -> {
                  PMField(field = parseProtectedField(st))
                }
              }
            }
            case _ -> {
              PMField(field = parseProtectedField(st))
            }
          }
        }
        case KwFunc -> {
          PMFunc(fn = parseFunctionDeclBody(st, None))
        }
        case KwAsync -> {
          PMFunc(fn = parseFunctionDeclBody(st, None))
        }
        case KwVar -> {
          PMField(field = parseProtectedField(st))
        }
        case KwLet -> {
          PMField(field = parseProtectedField(st))
        }
        case _ -> {
          PMField(field = parseProtectedField(st))
        }
      }
    }
    case _ -> {
      PMField(field = parseProtectedField(st))
    }
  }
}

func parseProtectedTypeBody(st: inout ParseState, genericsPrefix: Option[GenericParams]): ProtectedTypeDecl {
  val startTok = advance(st)
  // 'protected'
  val _ = advance(st)
  // 'type'
  val ns = readIdent(st, "protected type")
  val _ = skipStmtEnds(st)
  val genericsSuffix = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, genericsSuffix)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0241", "expected '{' to start protected type body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[ProtectedMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    xs.add(parseProtectedMember(st))
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0242", "expected '}' to close protected type body", peekSpan(st))
    }
  }
  val endSpan = lastSpan(st)
  ProtectedTypeDecl(
    name = ns.name,
    generics = generics,
    whereClause = whereClause,
    members = xs,
    span = joinSpans(startTok.span, endSpan)
  )
}

func parseWireMember(st: inout ParseState): WireMember {
  val startSpan = peekSpan(st)
  match peekToken(st) {
    case TPunct(p) -> {
      match p {
        case At -> {
          val next1 = peekAt(st, 1)
          if identStr(next1.token) == "provided" {
            val _ = advance(st)
            // @
            val _ = advance(st)
            // provided
            val ns = readIdent(st, "@provided")
            match tryEatPunct(st, Colon) {
              case Some(_) -> {
              }
              case None -> {
                emitErr(st, "P0250", "expected ':' after @provided name", peekSpan(st))
              }
            }
            val ty = parseTypeExpr(st)
            WMProvided(name = ns.name, ty = ty, span = joinSpans(startSpan, ty.span))
          } else {
            emitErr(st, "P0258", "expected wire member", peekSpan(st))
            if not isAtEnd(st) {
              val _ = advance(st)
            }
            WMExpose(name = "<error>", span = startSpan)
          }
        }
        case _ -> {
          emitErr(st, "P0258", "expected wire member", peekSpan(st))
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          WMExpose(name = "<error>", span = startSpan)
        }
      }
    }
    case TKeyword(k) -> {
      match k {
        case KwSingleton -> {
          val _ = advance(st)
          val ns = readIdent(st, "singleton")
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0251", "expected ':' after 'singleton' name", peekSpan(st))
            }
          }
          val ty = parseTypeExpr(st)
          match tryEatPunct(st, Eq) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0252", "expected '=' in singleton declaration", peekSpan(st))
            }
          }
          val init = parseExpr(st)
          WMSingleton(name = ns.name, ty = ty, init = init, span = joinSpans(startSpan, init.span))
        }
        case KwScoped -> {
          val _ = advance(st)
          match tryEatPunct(st, LBracket) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0253", "expected '[' after 'scoped'", peekSpan(st))
            }
          }
          val scopeNs = readIdent(st, "scope tag")
          match tryEatPunct(st, RBracket) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0254", "expected ']' to close 'scoped[…]'", peekSpan(st))
            }
          }
          val ns = readIdent(st, "scoped")
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0251", "expected ':' after 'scoped' name", peekSpan(st))
            }
          }
          val ty = parseTypeExpr(st)
          match tryEatPunct(st, Eq) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0252", "expected '=' in scoped declaration", peekSpan(st))
            }
          }
          val init = parseExpr(st)
          WMScoped(scopeName = scopeNs.name, name = ns.name, ty = ty, init = init, span = joinSpans(startSpan, init.span))
        }
        case KwBind -> {
          val _ = advance(st)
          val atom = parseAtomNonParenType(st)
          val iface = applyNullableSuffix(st, atom)
          match tryEatPunct(st, Arrow) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0255", "expected '->' in bind declaration", peekSpan(st))
            }
          }
          val provider = parseExpr(st)
          WMBind(iface = iface, provider = provider, span = joinSpans(startSpan, provider.span))
        }
        case KwVal -> {
          val _ = advance(st)
          val ns = readIdent(st, "wire-local val")
          val ty = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
          match tryEatPunct(st, Eq) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0257", "expected '=' in wire-local val", peekSpan(st))
            }
          }
          val init = parseExpr(st)
          WMLocal(name = ns.name, ty = ty, init = init, span = joinSpans(startSpan, init.span))
        }
        case KwUse -> {
          emitErr(st, "P0256", "unexpected 'use' inside wire body (did you mean 'expose'?)", peekSpan(st))
          val _ = advance(st)
          val ns = readIdent(st, "expose")
          WMExpose(name = ns.name, span = joinSpans(startSpan, ns.span))
        }
        case _ -> {
          emitErr(st, "P0258", "expected wire member", peekSpan(st))
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          WMExpose(name = "<error>", span = startSpan)
        }
      }
    }
    case TIdent(_) -> {
      if identStr(peekToken(st)) == "expose" {
        val _ = advance(st)
        val ns = readIdent(st, "expose")
        WMExpose(name = ns.name, span = joinSpans(startSpan, ns.span))
      } else {
        emitErr(st, "P0258", "expected wire member", peekSpan(st))
        if not isAtEnd(st) {
          val _ = advance(st)
        }
        WMExpose(name = "<error>", span = startSpan)
      }
    }
    case _ -> {
      emitErr(st, "P0258", "expected wire member", peekSpan(st))
      if not isAtEnd(st) {
        val _ = advance(st)
      }
      WMExpose(name = "<error>", span = startSpan)
    }
  }
}

func parseWireBody(st: inout ParseState): WireDecl {
  val startTok = advance(st)
  // 'wire'
  val ns = readIdent(st, "wire")
  val parameters = if isPunct(peekToken(st), LParen) { parseParamList(st) } else { newList() }
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0259", "expected '{' to start wire body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[WireMember] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    xs.add(parseWireMember(st))
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0260", "expected '}' to close wire body", peekSpan(st))
    }
  }
  val endSpan = lastSpan(st)
  WireDecl(name = ns.name, params = parameters, members = xs, span = joinSpans(startTok.span, endSpan))
}

func parseExternMemberOpt(st: inout ParseState): Option[ExternMemberDecl] {
  // Capture startSp before consuming docs/annotations so the span covers the
  // full member extent (including leading doc comments).
  val startSp = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  val vis: Option[Visibility] = match tryEatKw(st, KwPub) {
    case Some(t) -> Some(VisPub(span = t.span))
    case None -> None
  }
  val kindOpt: Option[ExternMember] = match peekToken(st) {
    case TKeyword(k) -> {
      match k {
        case KwExposed -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwRecord -> {
                  Some(EMExposedRec(decl = parseRecordBody(st, None, true)))
                }
                case KwType -> {
                  val _ = advance(st)
                  // 'exposed'
                  val inlineDecl = parseOpaqueTypeBody(st, None)
                  val exposedTag = Annotation(
                    name = ModulePath(segments = singletonStrList("exposed"), span = inlineDecl.span),
                    args = newList(),
                    span = inlineDecl.span
                  )
                  val taggedAnns: List[Annotation] = newList()
                  taggedAnns.add(exposedTag)
                  var i2 = 0
                  while i2 < inlineDecl.annotations.count {
                    taggedAnns.add(inlineDecl.annotations[i2])
                    i2 = i2 + 1
                  }
                  val tagged = OpaqueTypeDecl(
                    name = inlineDecl.name,
                    generics = inlineDecl.generics,
                    whereClause = inlineDecl.whereClause,
                    annotations = taggedAnns,
                    members = inlineDecl.members,
                    hasBody = inlineDecl.hasBody,
                    span = inlineDecl.span
                  )
                  Some(EMOpaque(decl = tagged))
                }
                case _ -> {
                  emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  None
                }
              }
            }
            case _ -> {
              emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              None
            }
          }
        }
        case KwRecord -> {
          Some(EMRecord(decl = parseRecordBody(st, None, false)))
        }
        case KwUnion -> {
          Some(EMUnion(decl = parseUnionBody(st, None)))
        }
        case KwEnum -> {
          Some(EMEnum(decl = parseEnumBody(st)))
        }
        case KwOpaque -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwType -> {
                  Some(EMOpaque(decl = parseOpaqueTypeBody(st, None)))
                }
                case _ -> {
                  emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  None
                }
              }
            }
            case _ -> {
              emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              None
            }
          }
        }
        case KwAlias -> {
          Some(EMTypeAlias(decl = parseTypeAliasBody(st, None)))
        }
        case KwType -> {
          Some(EMDistinctType(decl = parseDistinctTypeBody(st, None)))
        }
        case KwFunc -> {
          val fn = parseFunctionDeclBody(st, None)
          Some(
            EMSig(
              sig = FunctionSig(
                docComments = newList(),
                isAsync = fn.isAsync,
                name = fn.name,
                generics = fn.generics,
                params = fn.params,
                ret = fn.ret,
                whereClause = fn.whereClause,
                contracts = fn.contracts,
                span = fn.span
              )
            )
          )
        }
        case KwAsync -> {
          val fn = parseFunctionDeclBody(st, None)
          Some(
            EMSig(
              sig = FunctionSig(
                docComments = newList(),
                isAsync = fn.isAsync,
                name = fn.name,
                generics = fn.generics,
                params = fn.params,
                ret = fn.ret,
                whereClause = fn.whereClause,
                contracts = fn.contracts,
                span = fn.span
              )
            )
          )
        }
        case _ -> {
          emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          None
        }
      }
    }
    case _ -> {
      emitErr(st, "P0270", "expected an extern declaration", peekSpan(st))
      if not isAtEnd(st) {
        val _ = advance(st)
      }
      None
    }
  }
  match kindOpt {
    case Some(k) -> Some(ExternMemberDecl(docComments = docs, annotations = anns, visibility = vis, kind = k, span = startSp))
    case None -> None
  }
}

func parseExternPackageBody(st: inout ParseState, anns: List[Annotation]): ExternPackageDecl {
  val startTok = advance(st)
  // 'extern'
  val _ = advance(st)
  // 'package'
  val path = parseModulePath(st)
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0271", "expected '{' to start extern package body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val xs: List[ExternMemberDecl] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    match parseExternMemberOpt(st) {
      case Some(m) -> {
        xs.add(m)
      }
      case None -> {
      }
    }
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
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0272", "expected '}' to close extern package body", peekSpan(st))
    }
  }
  val endSpan = lastSpan(st)
  ExternPackageDecl(path = path, annotations = anns, members = xs, span = joinSpans(startTok.span, endSpan))
}

func parseExternTypeBody(st: inout ParseState): ExternTypeDecl {
  val startTok = advance(st)
  // 'extern'
  val _ = advance(st)
  // 'type'
  val ns = readIdent(st, "extern type")
  val generics = parseGenericParamsOpt(st)
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0273", "expected '=' after extern type name", peekSpan(st))
    }
  }
  val clrNameResult = match peekToken(st) {
    case TString(s) -> {
      val tok = advance(st)
      NameAndSpan(name = s, span = tok.span)
    }
    case TIdent(_) -> {
      val path = parseModulePath(st)
      NameAndSpan(name = modulePathJoin(path.segments), span = path.span)
    }
    case _ -> {
      emitErr(
        st,
        "P0274",
        "expected a type path or a string literal naming the host type (e.g. \"System.DateTime\")",
        peekSpan(st)
      )
      NameAndSpan(name = "<error>", span = peekSpan(st))
    }
  }
  var hasBacktick = false
  var sIdx = 0
  while sIdx < clrNameResult.name.length {
    if clrNameResult.name.substring(sIdx, 1) == "`" {
      hasBacktick = true
    }
    sIdx = sIdx + 1
  }
  val finalClrName = match generics {
    case Some(gps) -> {
      if gps.params.count > 0 and not hasBacktick {
        clrNameResult.name + "`" + toString(gps.params.count)
      } else {
        clrNameResult.name
      }
    }
    case None -> clrNameResult.name
  }
  ExternTypeDecl(
    name = ns.name,
    generics = generics,
    clrName = finalClrName,
    span = joinSpans(startTok.span, clrNameResult.span)
  )
}

/// `extern func <name>(<params>): <ret> = "<symbol>"` (D-N-007).  The
/// `= "symbol"` clause is mandatory; the symbol is a bare C identifier.
func parseExternFuncBody(st: inout ParseState): ExternFuncDecl {
  val startTok = advance(st)
  // 'extern'
  val _ = advance(st)
  // 'func'
  val ns = readIdent(st, "extern func")
  val parameters = parseParamList(st)
  val returnType = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0275", "expected '= \"symbol\"' after extern func signature", peekSpan(st))
    }
  }
  val symResult = match peekToken(st) {
    case TString(s) -> {
      val tok = advance(st)
      NameAndSpan(name = s, span = tok.span)
    }
    case _ -> {
      emitErr(st, "P0276", "expected a string literal naming the C symbol (e.g. \"write\")", peekSpan(st))
      NameAndSpan(name = "<error>", span = peekSpan(st))
    }
  }
  ExternFuncDecl(
    name = ns.name,
    params = parameters,
    ret = returnType,
    symbol = symResult.name,
    span = joinSpans(startTok.span, symResult.span)
  )
}

func parseModuleValBody(st: inout ParseState): ValDecl {
  val startTok = advance(st)
  // 'val'
  val pat = parsePattern(st)
  val ty = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0280", "expected '=' in module-level val", peekSpan(st))
    }
  }
  val init = parseExpr(st)
  ValDecl(pattern = pat, ty = ty, init = init, span = joinSpans(startTok.span, init.span))
}

func parseScopeKindBody(st: inout ParseState): ScopeKindDecl {
  val startTok = advance(st)
  // 'scope_kind' (TIdent)
  val ns = readIdent(st, "scope_kind")
  ScopeKindDecl(name = ns.name, span = joinSpans(startTok.span, ns.span))
}

// ─────────────────────────────────────────────────────────────────────────────
// D046 — `config Name { ... }` block parser.  Mirrors the F# bootstrap
// `parseConfigBody` in `compiler/src/Lyric.Parser/Parser.fs`.  Each field
// is `name: Type [= default]` with optional preceding annotations.
// ─────────────────────────────────────────────────────────────────────────────
func parseConfigField(st: inout ParseState): ConfigField {
  val startSpan = peekSpan(st)
  val docs = parseItemDocComments(st)
  val anns = parseItemAnnotations(st)
  val ns = readIdent(st, "config field")
  match tryEatPunct(st, Colon) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0120", "expected ':' after config field name", peekSpan(st))
    }
  }
  val ty = parseTypeExpr(st)
  val dflt = match tryEatPunct(st, Eq) { case Some(_) -> Some(parseExpr(st)); case None -> None }
  val trailingAnns = parseSameLineTrailingAnnotations(st)
  val allAnns = listConcat(anns, trailingAnns)
  val endSpan = match dflt { case Some(e) -> e.span; case None -> ty.span }
  ConfigField(
    docComments = docs,
    annotations = allAnns,
    name = ns.name,
    ty = ty,
    default = dflt,
    span = joinSpans(startSpan, endSpan)
  )
}

func parseConfigBody(st: inout ParseState): ConfigDecl {
  val startTok = advance(st)
  // 'config' (TIdent)
  val ns = readIdent(st, "config block")
  val _ = skipStmtEnds(st)
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0121", "expected '{' to start config block body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val fields: List[ConfigField] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = st.pos
    fields.add(parseConfigField(st))
    val sepTok = peekToken(st)
    match sepTok {
      case TStmtEnd -> {
        val _ = advance(st)
        val _ = skipStmtEnds(st)
      }
      case _ -> {
        if isPunct(sepTok, Comma) {
          val _ = advance(st)
          val _ = skipStmtEnds(st)
        }
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  val closeTok = tryEatPunct(st, RBrace)
  val endSpan = match closeTok {
    case Some(t) -> t.span
    case None -> {
      val sp = peekSpan(st)
      emitErr(st, "P0122", "expected '}' to close config block body", sp)
      sp
    }
  }
  ConfigDecl(name = ns.name, fields = fields, span = joinSpans(startTok.span, endSpan))
}

// ─────────────────────────────────────────────────────────────────────────────
// D047/D051 — `aspect Name { ... }` block parser.
// Three forms: standalone, template (pub, no matches), instantiation (from).
// ─────────────────────────────────────────────────────────────────────────────
/// Parse an anonymous `config { fields... }` block inside an aspect body.
/// Caller has already consumed the `config` keyword.
func parseAspectConfigBlock(st: inout ParseState): List[ConfigField] {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0306", "expected '{' to start aspect config block", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val fields: List[ConfigField] = newList()
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = st.pos
    fields.add(parseConfigField(st))
    val sepTok = peekToken(st)
    match sepTok {
      case TStmtEnd -> {
        val _ = advance(st)
        val _ = skipStmtEnds(st)
      }
      case _ -> {
        if isPunct(sepTok, Comma) {
          val _ = advance(st)
          val _ = skipStmtEnds(st)
        }
      }
    }
    forceAdvanceIfStuck(st, before)
  }
  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0307", "expected '}' to close aspect config block", peekSpan(st))
    }
  }
  fields
}

// Parse the `{ id, id, ... }` identifier set shared by the `name in { … }`
// predicate and the `except name in { … }` exclusion clause.  `ctx` names the
// clause for the brace diagnostics (e.g. "name in" / "except name in").
// Parsed identifiers are appended to `names`.
func parseAspectNameSet(st: inout ParseState, ctx: in String, names: inout List[String]): Unit {
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0321", "expected '{' after '" + ctx + "'", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  var moreNames = true
  while moreNames {
    match peekToken(st) {
      case TIdent(n) -> {
        val _ = advance(st)
        names.add(n)
        val _ = skipStmtEnds(st)
        match tryEatPunct(st, Comma) {
          case Some(_) -> {
            val _ = skipStmtEnds(st)
          }
          case None -> {
            moreNames = false
          }
        }
      }
      case _ -> {
        moreNames = false
      }
    }
  }
  match tryEatPunct(st, RBrace) {
    case Some(closeSp) -> {
      // An empty set `name in { }` is almost certainly a programming mistake —
      // the predicate would never match any function.
      if names.count == 0 {
        emitErr(st, "P0323", "'" + ctx + " { }' is always false — add at least one name to the set", closeSp.span)
      }
    }
    case None -> {
      emitErr(st, "P0322", "expected '}' to close '" + ctx + " { ... }'", peekSpan(st))
    }
  }
}

// Build a type-glob string from tokens until a boundary (newline/and/except/}).
// Parse one predicate. Returns None if the current token is not a predicate keyword.
func parseOneMatchPredicate(st: inout ParseState): Option[AspectMatcher] {
  match peekToken(st) {
    case TIdent(s) -> {
      if s == "name" {
        val nameSp = peekSpan(st)
        val _ = advance(st)
        // `name like "<glob>"` (glob match) or `name in { id, ... }` (set
        // membership).  `in` is a keyword; `like` is a contextual identifier.
        match peekToken(st) {
          case TKeyword(k) -> {
            if k == KwIn {
              val _ = advance(st)
              val names: List[String] = newList()
              parseAspectNameSet(st, "name in", names)
              // Convention: `span` is the span of the `name` keyword token
              // (the start of the predicate).  AMNameLike uses the glob literal span
              // (the end token); both strategies are valid — document whichever
              // you pick when adding new AMxxx variants so error reporting is consistent.
              Some(value = AMNameIn(names = names, span = nameSp))
            } else {
              emitErr(st, "P0298", "expected 'like' or 'in' after 'name'", peekSpan(st))
              None
            }
          }
          case TIdent(s2) -> {
            if s2 == "like" {
              val _ = advance(st)
              match peekToken(st) {
                case TString(g) -> {
                  val sp = peekSpan(st)
                  val _ = advance(st)
                  Some(value = AMNameLike(glob = g, span = sp))
                }
                case _ -> {
                  emitErr(st, "P0299", "expected a string-literal glob after 'name like'", peekSpan(st))
                  None
                }
              }
            } else {
              emitErr(st, "P0298", "expected 'like' or 'in' after 'name'", peekSpan(st))
              None
            }
          }
          case _ -> {
            emitErr(st, "P0298", "expected 'like' or 'in' after 'name'", peekSpan(st))
            None
          }
        }
      } else if s == "annotated" {
        val _ = advance(st)
        match tryEatPunct(st, Colon) {
          case Some(_) -> {
          }
          case None -> {
            emitErr(st, "P0310", "expected ':' after 'annotated'", peekSpan(st))
          }
        }
        if isPunct(peekToken(st), At) {
          val _ = advance(st)
          match peekToken(st) {
            case TIdent(n) -> {
              val sp = peekSpan(st)
              val _ = advance(st)
              Some(value = AMAnnotated(annotName = n, span = sp))
            }
            case _ -> {
              emitErr(st, "P0311", "expected annotation name after '@'", peekSpan(st))
              None
            }
          }
        } else {
          emitErr(st, "P0312", "expected '@AnnotName' in annotated: predicate", peekSpan(st))
          None
        }
      } else if s == "visibility" {
        val _ = advance(st)
        match tryEatPunct(st, Colon) {
          case Some(_) -> {
          }
          case None -> {
            emitErr(st, "P0313", "expected ':' after 'visibility'", peekSpan(st))
          }
        }
        val sp = peekSpan(st)
        match peekToken(st) {
          case TKeyword(k) -> {
            if k == KwPub {
              val _ = advance(st)
              Some(value = AMVisibility(vis = "pub", span = sp))
            } else if k == KwInternal {
              val _ = advance(st)
              Some(value = AMVisibility(vis = "internal", span = sp))
            } else {
              emitErr(st, "P0314", "expected 'pub', 'priv', or 'internal' after 'visibility:'", sp)
              None
            }
          }
          case TIdent(v) -> {
            if v == "priv" {
              val _ = advance(st)
              Some(value = AMVisibility(vis = "priv", span = sp))
            } else {
              emitErr(st, "P0314", "expected 'pub', 'priv', or 'internal' after 'visibility:'", sp)
              None
            }
          }
          case _ -> {
            emitErr(st, "P0314", "expected 'pub', 'priv', or 'internal' after 'visibility:'", sp)
            None
          }
        }
      } else if s == "signature" {
        val _ = advance(st)
        match tryEatPunct(st, Colon) {
          case Some(_) -> {
          }
          case None -> {
            emitErr(st, "P0315", "expected ':' after 'signature'", peekSpan(st))
          }
        }
        match peekToken(st) {
          case TIdent(kw) -> {
            if kw == "returns" {
              val sp = peekSpan(st)
              val _ = advance(st)
              match peekToken(st) {
                case TString(g) -> {
                  val sp2 = peekSpan(st)
                  val _ = advance(st)
                  Some(value = AMSignatureReturns(typeGlob = g, span = sp2))
                }
                case _ -> {
                  emitErr(st, "P0316", "expected a string-literal type glob after 'signature: returns'", peekSpan(st))
                  None
                }
              }
            } else {
              emitErr(st, "P0317", "expected 'returns' after 'signature:'", peekSpan(st))
              None
            }
          }
          case _ -> {
            emitErr(st, "P0317", "expected 'returns' after 'signature:'", peekSpan(st))
            None
          }
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// Parse a `matches:` clause: predicates joined by `and`, then optional
// `except name in { ... }`.  Results are appended to the supplied lists.
func parseAspectMatchesClause(
  st: inout ParseState, matchers: inout List[AspectMatcher], exceptNames: inout List[String]
): Unit {
  val _ = skipStmtEnds(st)
  match parseOneMatchPredicate(st) {
    case Some(m) -> matchers.add(m)
    case None -> emitErr(st, "P0297", "expected a predicate in matches: clause", peekSpan(st))
  }
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    match peekToken(st) {
      case TKeyword(k) -> {
        if k == KwAnd {
          val _ = advance(st)
          val _ = skipStmtEnds(st)
          match parseOneMatchPredicate(st) {
            case Some(m) -> matchers.add(m)
            case None -> {
              emitErr(st, "P0318", "expected a predicate after 'and'", peekSpan(st))
              keepGoing = false
            }
          }
        } else {
          keepGoing = false
        }
      }
      case _ -> {
        keepGoing = false
      }
    }
  }
  // Optional `except name in { ... }`
  val _ = skipStmtEnds(st)
  match peekToken(st) {
    case TIdent(kw) -> {
      if kw == "except" {
        val _ = advance(st)
        match peekToken(st) {
          case TIdent(k) -> {
            if k == "name" {
              val _ = advance(st)
            } else {
              emitErr(st, "P0319", "expected 'name' after 'except'", peekSpan(st))
            }
          }
          case _ -> {
            emitErr(st, "P0319", "expected 'name' after 'except'", peekSpan(st))
          }
        }
        match peekToken(st) {
          case TKeyword(k) -> {
            if k == KwIn {
              val _ = advance(st)
            } else {
              emitErr(st, "P0320", "expected 'in' after 'except name'", peekSpan(st))
            }
          }
          case _ -> {
            emitErr(st, "P0320", "expected 'in' after 'except name'", peekSpan(st))
          }
        }
        parseAspectNameSet(st, "except name in", exceptNames)
      }
    }
    case _ -> {
    }
  }
}

// One `name: Type` member of a `where TArgs has { ... }` row constraint.
func parseArgsRowField(st: inout ParseState): ArgsRowField {
  val startSpan = peekSpan(st)
  val ns = readIdent(st, "args row field")
  match tryEatPunct(st, Colon) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0324", "expected ':' after args row field name", peekSpan(st))
    }
  }
  val ty = parseTypeExpr(st)
  ArgsRowField(name = ns.name, ty = ty, span = joinSpans(startSpan, ty.span))
}

// P0331 — a row clause declares the same field name twice (#4620). Left
// undetected, `bmodeSynthArgsRecordItem` (weaver.l) would emit two same-named
// `RMField` members into the synthesised args record, surfacing as a
// confusing downstream type-checker error instead of a clear parse-time one.
func emitDuplicateArgsRowFieldDiags(st: inout ParseState, fields: in List[ArgsRowField]): Unit {
  var i = 1
  while i < fields.count {
    var j = 0
    var isDup = false
    while j < i {
      if fields[j].name == fields[i].name {
        isDup = true
      }
      j = j + 1
    }
    if isDup {
      emitErr(st, "P0331", "duplicate field '" + fields[i].name + "' in args row constraint", fields[i].span)
    }
    i = i + 1
  }
}

// `where TArgs has { field: Type, ... }` (docs/56 D115): a row constraint
// gating typed `args.<field>` access for a B'-mode `from`-instance template.
// `TArgs` and `has` are contextual, recognised only in this exact position
// (right after the around advice's return binder), mirroring how `from` /
// `matches` / `around` are contextual in `parseAspectBody` rather than
// reserved keywords — this doesn't reserve either word globally.
//
// Leading statement-ends are skipped before checking for `where` (#4619):
// without this, a row clause written on its own line (the lexer inserts a
// `TStmtEnd` after `ret`) would never be recognised — `where` would be
// mistaken for the start of the next statement and the clause silently
// dropped, with no diagnostic pointing at why. `parseAspectAround`'s own
// `skipStmtEnds` call right after this one (for the "no row clause" case,
// stmt-end before `{`) still runs; skipping twice is a harmless no-op.
func parseArgsRowClauseOpt(st: inout ParseState): Option[List[ArgsRowField]] {
  val _ = skipStmtEnds(st)
  if not isKw(peekToken(st), KwWhere) {
    None
  } else {
    val _ = advance(st)
    // 'where'
    val nameTok = peek(st)
    match tryEatIdent(st) {
      case Some(ns) -> {
        if ns.name != "TArgs" {
          emitErr(
            st,
            "P0326",
            "expected 'TArgs' in around advice where-clause (only the compiler-synthesised args type may be constrained here)",
            ns.span
          )
        }
      }
      case None -> {
        // Missing identifier entirely — P0325 alone is the diagnostic; don't
        // also fire P0326 for a synthesized "<error>" name that trivially
        // isn't "TArgs" (that would be a second, misleading diagnostic on
        // already-bad input).
        emitErr(st, "P0325", "expected 'TArgs' after 'where' in around advice", nameTok.span)
      }
    }
    val hasTok = peek(st)
    match tryEatIdent(st) {
      case Some(ns) -> {
        if ns.name != "has" {
          emitErr(st, "P0327", "expected 'has' after 'where TArgs'", ns.span)
        }
      }
      case None -> {
        emitErr(st, "P0327", "expected 'has' after 'where TArgs'", hasTok.span)
      }
    }
    match tryEatPunct(st, LBrace) {
      case Some(_) -> {
      }
      case None -> {
        emitErr(st, "P0328", "expected '{' to start args row constraint", peekSpan(st))
      }
    }
    val _ = skipStmtEnds(st)
    val fields: List[ArgsRowField] = newList()
    while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
      val before = st.pos
      fields.add(parseArgsRowField(st))
      val sepTok = peekToken(st)
      match sepTok {
        case TStmtEnd -> {
          val _ = advance(st)
          val _ = skipStmtEnds(st)
        }
        case _ -> {
          if isPunct(sepTok, Comma) {
            val _ = advance(st)
            val _ = skipStmtEnds(st)
          }
        }
      }
      forceAdvanceIfStuck(st, before)
    }
    val closeSpan = peekSpan(st)
    match tryEatPunct(st, RBrace) {
      case Some(_) -> {
        // Only diagnose an empty clause once the `}` is actually confirmed:
        // when it's missing entirely, P0329 already names the problem, and a
        // fields.count == 0 check here would fire a second, misleading
        // diagnostic on the same malformed input.
        if fields.count == 0 {
          emitErr(
            st,
            "P0330",
            "args row constraint must declare at least one field (`where TArgs has { field: Type }`)",
            closeSpan
          )
        }
      }
      case None -> {
        emitErr(st, "P0329", "expected '}' to close args row constraint", peekSpan(st))
      }
    }
    emitDuplicateArgsRowFieldDiags(st, fields)
    Some(value = fields)
  }
}

func parseAspectAround(st: inout ParseState): AspectAround {
  val startTok = advance(st)
  // 'around'
  match tryEatPunct(st, LParen) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0301", "expected '(' after 'around'", peekSpan(st))
    }
  }
  val args = readIdent(st, "around args")
  match tryEatPunct(st, RParen) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0302", "expected ')' after around args binder", peekSpan(st))
    }
  }
  // The return binder is threaded through a `var` rather than an
  // `if … { … Some(x) } else { None }` value-expression: the stage-0
  // bootstrap emitter mis-lowers an `if`/`else` whose branches yield an
  // `Option`, silently producing the `None` arm and dropping the `-> ret`
  // binder.  A `var`-accumulator sidesteps that codegen bug.
  var ret: Option[String] = None
  if isPunct(peekToken(st), Arrow) {
    val _ = advance(st)
    val r = readIdent(st, "around return")
    ret = Some(value = r.name)
  }
  val argsRow = parseArgsRowClauseOpt(st)
  val _ = skipStmtEnds(st)
  val body = parseBlock(st)
  AspectAround(
    argsName = args.name,
    retName = ret,
    argsRow = argsRow,
    body = body,
    span = joinSpans(startTok.span, body.span)
  )
}

func parseAspectBody(st: inout ParseState): AspectDecl {
  val startTok = advance(st)
  // 'aspect' (TIdent)
  val ns = readIdent(st, "aspect")
  // Optional `from Pkg.Template` clause (instantiation form, D051).
  val fromPath: Option[ModulePath] = match peekToken(st) {
    case TIdent(s) -> {
      if s == "from" {
        val _ = advance(st)
        Some(parseModulePath(st))
      } else {
        None
      }
    }
    case _ -> None
  }
  val _ = skipStmtEnds(st)
  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0300", "expected '{' to start aspect body", peekSpan(st))
    }
  }
  val _ = skipStmtEnds(st)
  val matches: List[AspectMatcher] = newList()
  val exceptNames: List[String] = newList()
  val config: List[ConfigField] = newList()
  var configSeen: Bool = false
  val contracts: List[ContractClause] = newList()
  val wraps: List[String] = newList()
  val inside: List[String] = newList()
  var around: Option[AspectAround] = None
  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = st.pos
    match peekToken(st) {
      case TIdent(s) -> {
        if s == "matches" {
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0296", "expected ':' after 'matches'", peekSpan(st))
            }
          }
          parseAspectMatchesClause(st, matches, exceptNames)
        } else if s == "config" {
          if not configSeen {
            val _ = advance(st)
            val fields = parseAspectConfigBlock(st)
            for f in fields {
              config.add(f)
            }
            configSeen = true
          } else {
            emitErr(st, "P0308", "duplicate 'config' block in aspect body", peekSpan(st))
            val _ = advance(st)
            val _ = parseAspectConfigBlock(st)
          }
        } else if s == "around" {
          match around {
            case Some(_) -> {
              emitErr(st, "P0303", "duplicate 'around' clause in aspect block", peekSpan(st))
              // Skip the duplicate by parsing it for error recovery.
              val _ = parseAspectAround(st)
            }
            case None -> {
              around = Some(value = parseAspectAround(st))
            }
          }
        } else if s == "wraps" {
          // §6 ordering: `wraps: A, B` — this aspect runs outside A and B.
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0306", "expected ':' after 'wraps'", peekSpan(st))
            }
          }
          var keepGoing = true
          while keepGoing {
            val _ = skipStmtEnds(st)
            match peekToken(st) {
              case TIdent(n) -> {
                val _ = advance(st)
                wraps.add(n)
                val _ = skipStmtEnds(st)
                match tryEatPunct(st, Comma) {
                  case Some(_) -> {
                  }
                  case None -> {
                    keepGoing = false
                  }
                }
              }
              case _ -> {
                keepGoing = false
              }
            }
          }
        } else if s == "inside" {
          // §6 ordering: `inside: A, B` — this aspect runs inside A and B.
          val _ = advance(st)
          match tryEatPunct(st, Colon) {
            case Some(_) -> {
            }
            case None -> {
              emitErr(st, "P0307", "expected ':' after 'inside'", peekSpan(st))
            }
          }
          var keepGoing = true
          while keepGoing {
            val _ = skipStmtEnds(st)
            match peekToken(st) {
              case TIdent(n) -> {
                val _ = advance(st)
                inside.add(n)
                val _ = skipStmtEnds(st)
                match tryEatPunct(st, Comma) {
                  case Some(_) -> {
                  }
                  case None -> {
                    keepGoing = false
                  }
                }
              }
              case _ -> {
                keepGoing = false
              }
            }
          }
        } else {
          emitErr(
            st,
            "P0304",
            "expected 'matches:', 'config', 'around', 'wraps:', 'inside:', 'requires:', or 'ensures:' in aspect body",
            peekSpan(st)
          )
          val _ = advance(st)
        }
      }
      case TKeyword(k) -> {
        // §5 contract augmentation: requires:/ensures: on aspect body
        if k == KwRequires or k == KwEnsures {
          match parseContractClauseOpt(st) {
            case Some(c) -> contracts.add(c)
            case None -> {
            }
          }
        } else {
          emitErr(
            st,
            "P0304",
            "expected 'matches:', 'around', 'wraps:', 'inside:', 'requires:', or 'ensures:' in aspect body",
            peekSpan(st)
          )
          if not isAtEnd(st) {
            val _ = advance(st)
          }
        }
      }
      case _ -> {
        emitErr(
          st,
          "P0304",
          "expected 'matches:', 'config', 'around', 'wraps:', 'inside:', 'requires:', or 'ensures:' in aspect body",
          peekSpan(st)
        )
        if not isAtEnd(st) {
          val _ = advance(st)
        }
      }
    }
    val _ = skipStmtEnds(st)
    forceAdvanceIfStuck(st, before)
  }
  val closeTok = tryEatPunct(st, RBrace)
  val endSpan = match closeTok {
    case Some(t) -> t.span
    case None -> {
      val sp = peekSpan(st)
      emitErr(st, "P0305", "expected '}' to close aspect body", sp)
      sp
    }
  }
  AspectDecl(
    name = ns.name,
    from = fromPath,
    config = config,
    matches = matches,
    exceptNames = exceptNames,
    around = around,
    contracts = contracts,
    wraps = wraps,
    inside = inside,
    span = joinSpans(startTok.span, endSpan)
  )
}

func parseTestBody(st: inout ParseState): TestDecl {
  val startTok = advance(st)
  // 'test'
  val title = match peekToken(st) {
    case TString(s) -> {
      val _ = advance(st)
      s
    }
    case _ -> {
      val sp = peekSpan(st)
      emitErr(st, "P0290", "expected a string literal as test name", sp)
      "<error>"
    }
  }
  val _ = skipStmtEnds(st)
  val body = parseBlock(st)
  TestDecl(title = title, body = body, span = joinSpans(startTok.span, body.span))
}

func parsePropertyBinder(st: inout ParseState): PropertyBinder {
  val ns = readIdent(st, "property binder")
  match tryEatPunct(st, Colon) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0291", "expected ':' in property binder", peekSpan(st))
    }
  }
  val ty = parseTypeExpr(st)
  PropertyBinder(name = ns.name, ty = ty, span = joinSpans(ns.span, ty.span))
}

func parsePropertyBody(st: inout ParseState): PropertyDecl {
  val startTok = advance(st)
  // 'property'
  val title = match peekToken(st) {
    case TString(s) -> {
      val _ = advance(st)
      s
    }
    case _ -> {
      val sp = peekSpan(st)
      emitErr(st, "P0292", "expected a string literal as property name", sp)
      "<error>"
    }
  }
  val binders: List[PropertyBinder] = newList()
  if identStr(peekToken(st)) == "forall" {
    val _ = advance(st)
    match tryEatPunct(st, LParen) {
      case Some(_) -> {
      }
      case None -> {
        emitErr(st, "P0293", "expected '(' after 'forall' in property", peekSpan(st))
      }
    }
    if not isPunct(peekToken(st), RParen) {
      binders.add(parsePropertyBinder(st))
      while isPunct(peekToken(st), Comma) {
        val _ = advance(st)
        if not isPunct(peekToken(st), RParen) {
          binders.add(parsePropertyBinder(st))
        }
      }
    }
    match tryEatPunct(st, RParen) {
      case Some(_) -> {
      }
      case None -> {
        emitErr(st, "P0294", "expected ')' to close 'forall' binder list", peekSpan(st))
      }
    }
  }
  val _ = skipStmtEnds(st)
  val whereExpr: Option[Expr] = match tryEatKw(st, KwWhere) { case Some(_) -> Some(parseExpr(st)); case None -> None }
  val _ = skipStmtEnds(st)
  val body = parseBlock(st)
  PropertyDecl(
    title = title,
    forAll = binders,
    guardExpr = whereExpr,
    body = body,
    span = joinSpans(startTok.span, body.span)
  )
}

func parseFixtureBody(st: inout ParseState): FixtureDecl {
  val startTok = advance(st)
  // 'fixture'
  val ns = readIdent(st, "fixture")
  val ty = match tryEatPunct(st, Colon) { case Some(_) -> Some(parseTypeExpr(st)); case None -> None }
  match tryEatPunct(st, Eq) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0295", "expected '=' in fixture declaration", peekSpan(st))
    }
  }
  val init = parseExpr(st)
  FixtureDecl(name = ns.name, nameSpan = ns.span, ty = ty, init = init, span = joinSpans(startTok.span, init.span))
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: create a singleton List[String] (used for synthetic annotations).
// ─────────────────────────────────────────────────────────────────────────────
func singletonStrList(s: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(s)
  xs
}

// Helper: concatenate two lists (used for combining field annotations).
func listConcat(a: in List[Annotation], b: in List[Annotation]): List[Annotation] {
  val combined: List[Annotation] = newList()
  var i = 0
  while i < a.count {
    combined.add(a[i])
    i = i + 1
  }
  var j = 0
  while j < b.count {
    combined.add(b[j])
    j = j + 1
  }
  combined
}

func isFlatImpl(st: in ParseState): Bool {
  var i = st.pos
  while i < st.tokens.count {
    val tok = st.tokens[i].token
    match tok {
      case TKeyword(k) -> {
        match k {
          case KwFor -> {
            return true
          }
          case KwWhere -> {
            return false
          }
          case _ -> {
          }
        }
      }
      case TPunct(p) -> {
        match p {
          case LBrace -> {
            return false
          }
          case _ -> {
          }
        }
      }
      case TEof -> {
        return false
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

func parseNestedImpl(
  st: inout ParseState,
  docs: in List[DocComment],
  anns: in List[Annotation],
  vis: in Option[Visibility],
  genericsPrefix: in Option[GenericParams],
  prefixStart: in Span,
): List[Item] {
  val startTok = advance(st) // 'impl'
  val suffixGenerics = parseGenericParamsOpt(st)
  val generics = mergeGenericsInfo(st, genericsPrefix, suffixGenerics)

  val target = parseTypeExpr(st)
  val _ = skipStmtEnds(st)
  val whereClause = parseWhereClauseOpt(st)
  val _ = skipStmtEnds(st)
  val _ = parseTrailingAnnotations(st)

  match tryEatPunct(st, LBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0181", "expected '{' to start nested satisfies block", peekSpan(st))
    }
  }

  val _ = skipStmtEnds(st)
  val items: List[Item] = newList()

  while not isPunct(peekToken(st), RBrace) and not isAtEnd(st) {
    val before = mark(st)
    val satisfDocs = parseItemDocComments(st)
    val satisfAnns = parseItemAnnotations(st)
    val _ = skipStmtEnds(st)

    match tryEatKw(st, KwSatisfies) {
      case Some(_) -> {
      }
      case None -> {
        emitErr(st, "P0182", "expected 'satisfies' keyword", peekSpan(st))
        if not isAtEnd(st) {
          val _ = advance(st)
        }
        val _ = skipStmtEnds(st)
      }
    }

    val iface = parseConstraintRef(st)
    val _ = skipStmtEnds(st)
    val _ = parseTrailingAnnotations(st)
    val members = parseImplMembers(st)
    val endSpan = lastSpan(st)

    val decl = ImplDecl(
      generics = generics,
      iface = iface,
      target = target,
      whereClause = whereClause,
      members = members,
      span = joinSpans(startTok.span, endSpan)
    )

    val combinedDocs: List[DocComment] = newList()
    var d = 0
    while d < docs.count {
      combinedDocs.add(docs[d])
      d = d + 1
    }
    d = 0
    while d < satisfDocs.count {
      combinedDocs.add(satisfDocs[d])
      d = d + 1
    }

    val combinedAnns: List[Annotation] = newList()
    var a = 0
    while a < anns.count {
      combinedAnns.add(anns[a])
      a = a + 1
    }
    a = 0
    while a < satisfAnns.count {
      combinedAnns.add(satisfAnns[a])
      a = a + 1
    }

    val item = Item(
      docComments = combinedDocs,
      annotations = combinedAnns,
      visibility = vis,
      kind = IImpl(decl = decl),
      span = joinSpans(prefixStart, endSpan)
    )
    items.add(item)

    val _ = skipStmtEnds(st)
    forceAdvanceIfStuck(st, before)
  }

  match tryEatPunct(st, RBrace) {
    case Some(_) -> {
    }
    case None -> {
      emitErr(st, "P0183", "expected '}' to close nested satisfies block", peekSpan(st))
    }
  }

  items
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level item loop.
// ─────────────────────────────────────────────────────────────────────────────
func parseItemOpt(st: inout ParseState): Option[List[Item]] {
  val _ = skipStmtEnds(st)
  if isAtEnd(st) {
    return None
  }
  cstStart(st, SkItem)

  val prefixStart = peekSpan(st)
  val docs = parseItemDocComments(st)
  val collectedAnns: List[Annotation] = newList()
  var vis: Option[Visibility] = None
  var genericsPrefix: Option[GenericParams] = None
  var progress = true

  while progress {
    val _ = skipStmtEnds(st)
    match peekToken(st) {
      case TKeyword(k) -> {
        match k {
          case KwPub -> {
            match vis {
              case None -> {
                val t = advance(st)
                vis = Some(VisPub(span = t.span))
              }
              case Some(_) -> {
                progress = false
              }
            }
          }
          case KwInternal -> {
            match vis {
              case None -> {
                val t = advance(st)
                vis = Some(VisInternal(span = t.span))
              }
              case Some(_) -> {
                progress = false
              }
            }
          }
          case KwGeneric -> {
            match genericsPrefix {
              case None -> {
                genericsPrefix = parseGenericParamsOpt(st)
              }
              case Some(_) -> {
                progress = false
              }
            }
          }
          case _ -> {
            progress = false
          }
        }
      }
      case TPunct(p) -> {
        match p {
          case At -> {
            match parseAnnotation(st) {
              case Some(a) -> {
                collectedAnns.add(a)
              }
              case None -> {
                progress = false
              }
            }
          }
          case _ -> {
            progress = false
          }
        }
      }
      case _ -> {
        progress = false
      }
    }
  }

  val anns: List[Annotation] = collectedAnns
  val nextTok = peek(st)

  match nextTok.token {
    case TKeyword(k) -> {
      match k {
        case KwImpl -> {
          if not isFlatImpl(st) {
            val nestedItems = parseNestedImpl(st, docs, anns, vis, genericsPrefix, prefixStart)
            cstFinish(st)
            return Some(value = nestedItems)
          }
        }
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }

  val kind = match nextTok.token {
    case TKeyword(k) -> {
      match k {
        case KwAlias -> {
          ITypeAlias(decl = parseTypeAliasBody(st, genericsPrefix))
        }
        case KwType -> {
          IDistinctType(decl = parseDistinctTypeBody(st, genericsPrefix))
        }
        case KwRecord -> {
          IRecord(decl = parseRecordBody(st, genericsPrefix, false))
        }
        case KwExposed -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwRecord -> {
                  IExposedRec(decl = parseRecordBody(st, genericsPrefix, true))
                }
                case _ -> {
                  emitErr(st, "P0040", "expected an item declaration", nextTok.span)
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  IError
                }
              }
            }
            case _ -> {
              emitErr(st, "P0040", "expected an item declaration", nextTok.span)
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              IError
            }
          }
        }
        case KwUnion -> {
          IUnion(decl = parseUnionBody(st, genericsPrefix))
        }
        case KwEnum -> {
          match genericsPrefix {
            case Some(g) -> {
              emitErr(st, "P0100", "enum does not accept generic parameters", g.span)
            }
            case None -> {
            }
          }
          IEnum(decl = parseEnumBody(st))
        }
        case KwOpaque -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwType -> {
                  IOpaque(decl = parseOpaqueTypeBody(st, genericsPrefix))
                }
                case _ -> {
                  emitErr(st, "P0040", "expected an item declaration", nextTok.span)
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  IError
                }
              }
            }
            case _ -> {
              emitErr(st, "P0040", "expected an item declaration", nextTok.span)
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              IError
            }
          }
        }
        case KwFunc -> {
          val fn0 = parseFunctionDeclBody(st, genericsPrefix)
          val fn = FunctionDecl(
            docComments = docs,
            annotations = anns,
            visibility = vis,
            isAsync = fn0.isAsync,
            name = fn0.name,
            generics = fn0.generics,
            params = fn0.params,
            ret = fn0.ret,
            whereClause = fn0.whereClause,
            contracts = fn0.contracts,
            body = fn0.body,
            span = fn0.span
          )
          IFunc(decl = fn)
        }
        case KwAsync -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwFunc -> {
                  val fn0 = parseFunctionDeclBody(st, genericsPrefix)
                  val fn = FunctionDecl(
                    docComments = docs,
                    annotations = anns,
                    visibility = vis,
                    isAsync = fn0.isAsync,
                    name = fn0.name,
                    generics = fn0.generics,
                    params = fn0.params,
                    ret = fn0.ret,
                    whereClause = fn0.whereClause,
                    contracts = fn0.contracts,
                    body = fn0.body,
                    span = fn0.span
                  )
                  IFunc(decl = fn)
                }
                case _ -> {
                  emitErr(st, "P0040", "expected an item declaration", nextTok.span)
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  IError
                }
              }
            }
            case _ -> {
              emitErr(st, "P0040", "expected an item declaration", nextTok.span)
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              IError
            }
          }
        }
        case KwInterface -> {
          IInterface(decl = parseInterfaceBody(st, genericsPrefix))
        }
        case KwImpl -> {
          IImpl(decl = parseImplBody(st, genericsPrefix))
        }
        case KwProtected -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwType -> {
                  IProtected(decl = parseProtectedTypeBody(st, genericsPrefix))
                }
                case _ -> {
                  emitErr(st, "P0040", "expected an item declaration", nextTok.span)
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  IError
                }
              }
            }
            case _ -> {
              emitErr(st, "P0040", "expected an item declaration", nextTok.span)
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              IError
            }
          }
        }
        case KwWire -> {
          IWire(decl = parseWireBody(st))
        }
        case KwExtern -> {
          val next1 = peekAt(st, 1)
          match next1.token {
            case TKeyword(k2) -> {
              match k2 {
                case KwPackage -> {
                  IExtern(decl = parseExternPackageBody(st, anns))
                }
                case KwType -> {
                  IExternType(decl = parseExternTypeBody(st))
                }
                case KwFunc -> {
                  IExternFunc(decl = parseExternFuncBody(st))
                }
                case _ -> {
                  emitErr(st, "P0040", "expected an item declaration", nextTok.span)
                  if not isAtEnd(st) {
                    val _ = advance(st)
                  }
                  IError
                }
              }
            }
            case _ -> {
              emitErr(st, "P0040", "expected an item declaration", nextTok.span)
              if not isAtEnd(st) {
                val _ = advance(st)
              }
              IError
            }
          }
        }
        case KwVal -> {
          IVal(decl = parseModuleValBody(st))
        }
        case KwTest -> {
          ITest(decl = parseTestBody(st))
        }
        case KwProperty -> {
          IProperty(decl = parsePropertyBody(st))
        }
        case KwFixture -> {
          IFixture(decl = parseFixtureBody(st))
        }
        case _ -> {
          emitErr(st, "P0040", "expected an item declaration", nextTok.span)
          if not isAtEnd(st) {
            val _ = advance(st)
          }
          IError
        }
      }
    }
    case TIdent(_) -> {
      val identName = identStr(nextTok.token)
      // D046 / D047: `config` and `aspect` are context-sensitive item
      // starters — they must be followed by an identifier so the
      // names remain usable as parameters or local-variable names
      // in normal code.
      val nextIsIdent = match peekAt(st, 1).token { case TIdent(_) -> true; case _ -> false }
      if identName == "scope_kind" {
        IScopeKind(decl = parseScopeKindBody(st))
      } else if identName == "config" and nextIsIdent {
        IConfig(decl = parseConfigBody(st))
      } else if identName == "aspect" and nextIsIdent {
        IAspect(decl = parseAspectBody(st))
      } else {
        emitErr(st, "P0040", "expected an item declaration", nextTok.span)
        if not isAtEnd(st) {
          val _ = advance(st)
        }
        IError
      }
    }
    case _ -> {
      emitErr(st, "P0040", "expected an item declaration", nextTok.span)
      if not isAtEnd(st) {
        val _ = advance(st)
      }
      IError
    }
  }

  val endSpan = lastSpan(st)
  val item = Item(
    docComments = docs,
    annotations = anns,
    visibility = vis,
    kind = kind,
    span = joinSpans(prefixStart, endSpan)
  )
  cstFinish(st)
  val ys: List[Item] = newList()
  ys.add(item)
  Some(value = ys)
}

func parseItems(st: inout ParseState): List[Item] {
  cstStart(st, SkItemSection)
  val xs: List[Item] = newList()
  var keepGoing = true
  while keepGoing {
    match parseItemOpt(st) {
      case Some(its) -> {
        var i = 0
        while i < its.count {
          xs.add(its[i])
          i = i + 1
        }
      }
      case None -> {
        keepGoing = false
      }
    }
  }
  cstFinish(st)
  xs
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func parse(source: in String): ParseResult {
  val lexResult = lex(source)
  var st = makeParseState(lexResult.tokens, lexResult.diagnostics)
  // Wrap the entire file in a single SkSourceFile CST node so every
  // token (including the trailing TEof) is reachable from a single
  // root for the formatter / LSP to walk.
  cstStart(st, SkSourceFile)
  val startSpan = peekSpan(st)
  val moduleDoc = parseModuleDocComments(st)
  val fileAnnotations = parseFileLevelAnnotations(st)
  val packageDecl = parsePackageDecl(st)
  val imports = parseImports(st)
  val items = parseItems(st)
  val endSpan = peekSpan(st)
  // Drain any trailing STMT_END / EOF tokens so they fall under the
  // root node rather than dangling outside the CST.  The final TEof
  // is reached but `advance` won't step past it; bump `st.pos` to
  // `tokens.count` so trailing trivia attached to TEof is captured.
  val _ = skipStmtEnds(st)
  while st.pos < st.tokens.count {
    st.pos = st.pos + 1
  }
  cstFinish(st)
  val file = SourceFile(
    moduleDoc = moduleDoc,
    fileAnnotations = fileAnnotations,
    packageDecl = packageDecl,
    imports = imports,
    items = items,
    span = joinSpans(startSpan, endSpan)
  )
  val cst = buildGreenTree(st.cstEvents, st.tokens)
  ParseResult(file = file, diagnostics = st.diags, cst = cst, source = source)
}
