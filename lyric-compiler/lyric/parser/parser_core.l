// parser_core.l — ParseState, cursor helpers, token predicates, span
// utilities, diagnostics, module-path, annotations, package, imports.
// Mirrors Lyric.Parser.Cursor + the top-of-file parsing logic in
// compiler/src/Lyric.Parser/Parser.fs (parseModulePath through parseImports).
package Lyric.Parser

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// Helper record: named (name, span) pair — avoids tuple returns.
// ─────────────────────────────────────────────────────────────────────────────

pub record NameAndSpan {
  name: String
  span: Span
}

// ─────────────────────────────────────────────────────────────────────────────
// ParseState — mutable cursor over a token stream.
// ─────────────────────────────────────────────────────────────────────────────

pub record ParseState {
  tokens:    List[SpannedToken]
  pos:       Int
  diags:     List[Diagnostic]
  /// Concrete-syntax-tree event log — see `parser_cst.l`.  Token
  /// indices in `CeStart` / `CeFinish` reference `tokens` directly,
  /// so internal `mark` / `reset` speculation does not need to
  /// truncate the log.
  cstEvents: List[CstEvent]
}

pub func makeParseState(tokens: in List[SpannedToken], diags: in List[Diagnostic]): ParseState {
  val events: List[CstEvent] = newList()
  ParseState(tokens = tokens, pos = 0, diags = diags, cstEvents = events)
}

// ─────────────────────────────────────────────────────────────────────────────
// CST event helpers.  Each parser production wraps its body with
// `cstStart(st, kind)` ... `cstFinish(st)`; tokens consumed in
// between (via `advance` / `tryEatXxx`) are claimed by that node.
// ─────────────────────────────────────────────────────────────────────────────

pub func cstStart(st: inout ParseState, kind: in SyntaxKind): Unit {
  st.cstEvents.add(CeStart(kind = kind, tokenStart = st.pos))
}

pub func cstFinish(st: inout ParseState): Unit {
  st.cstEvents.add(CeFinish(tokenEnd = st.pos))
}

// ─────────────────────────────────────────────────────────────────────────────
// Cursor helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func isAtEnd(st: in ParseState): Bool {
  if st.pos >= st.tokens.count {
    true
  } else {
    match st.tokens[st.pos].token {
      case TEof -> true
      case _ -> false
    }
  }
}

// #425 item 3: a recovery-path peek beyond the last token used to
// return a synthetic `TEof` with span 0:0, which makes diagnostics
// raised against the synthetic token point at the start of the file
// instead of the real EOF.  Anchor the synthetic token at the end of
// the source: prefer the last real token's end position (which is
// the EOF that the lexer always appends), and fall back to
// `initialPosition()` only when the token stream is truly empty.
@pure
func syntheticEofSpan(st: in ParseState): Span {
  if st.tokens.count == 0 {
    pointSpan(initialPosition())
  } else {
    pointSpan(st.tokens[st.tokens.count - 1].span.endPos)
  }
}

pub func peek(st: in ParseState): SpannedToken {
  if st.pos >= st.tokens.count {
    makeSpannedToken(TEof, syntheticEofSpan(st))
  } else {
    st.tokens[st.pos]
  }
}

pub func peekAt(st: in ParseState, k: in Int): SpannedToken {
  val i = st.pos + k
  if i < 0 or i >= st.tokens.count {
    makeSpannedToken(TEof, syntheticEofSpan(st))
  } else {
    st.tokens[i]
  }
}

pub func peekToken(st: in ParseState): Token {
  peek(st).token
}

pub func peekSpan(st: in ParseState): Span {
  peek(st).span
}

// Return the span of the last consumed token.  If no token has been
// consumed yet (pos == 0), falls back to syntheticEofSpan so callers
// get a well-formed Span in all cases.  Use this (rather than peekSpan)
// when recording an end-of-production span so the item span ends at the
// last character of the item, not at the first character of the next one.
pub func lastSpan(st: in ParseState): Span {
  if st.pos == 0 {
    syntheticEofSpan(st)
  } else {
    st.tokens[st.pos - 1].span
  }
}

pub func advance(st: inout ParseState): SpannedToken {
  val t = peek(st)
  if st.pos < st.tokens.count { st.pos = st.pos + 1 }
  t
}

pub func mark(st: in ParseState): Int { st.pos }

pub func reset(st: inout ParseState, pos: in Int) {
  st.pos = pos
}

pub func skipStmtEnds(st: inout ParseState): Int {
  var n = 0
  var keepGoing = true
  while keepGoing {
    match peekToken(st) {
      case TStmtEnd -> {
        st.pos = st.pos + 1
        n = n + 1
      }
      case _ -> { keepGoing = false }
    }
  }
  n
}

// ─────────────────────────────────────────────────────────────────────────────
// Token predicate helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func isKw(tok: in Token, kw: in Keyword): Bool {
  match tok {
    case TKeyword(k) -> k == kw
    case _ -> false
  }
}

pub func isPunct(tok: in Token, p: in Punct): Bool {
  match tok {
    case TPunct(q) -> q == p
    case _ -> false
  }
}

pub func identStr(tok: in Token): String {
  match tok {
    case TIdent(name) -> name
    case _ -> ""
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Token-eating helpers — return Option[SpannedToken].
// ─────────────────────────────────────────────────────────────────────────────

pub func tryEatKw(st: inout ParseState, kw: in Keyword): Option[SpannedToken] {
  val t = peek(st)
  if isKw(t.token, kw) {
    st.pos = st.pos + 1
    Some(value = t)
  } else {
    None
  }
}

pub func tryEatPunct(st: inout ParseState, p: in Punct): Option[SpannedToken] {
  val t = peek(st)
  if isPunct(t.token, p) {
    st.pos = st.pos + 1
    Some(value = t)
  } else {
    None
  }
}

pub func tryEatIdent(st: inout ParseState): Option[NameAndSpan] {
  val t = peek(st)
  match t.token {
    case TIdent(name) -> {
      st.pos = st.pos + 1
      Some(value = NameAndSpan(name = name, span = t.span))
    }
    case _ -> None
  }
}

// `result` is a contextual keyword: valid as an identifier everywhere
// except inside `ensures:` expression position.
pub func tryEatIdentOrContextual(st: inout ParseState): Option[NameAndSpan] {
  val t = peek(st)
  match t.token {
    case TIdent(name) -> {
      st.pos = st.pos + 1
      Some(value = NameAndSpan(name = name, span = t.span))
    }
    case TKeyword(k) -> {
      match k {
        case KwResult -> {
          st.pos = st.pos + 1
          Some(value = NameAndSpan(name = "result", span = t.span))
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

// Accept an identifier OR any keyword as a member / method name after `.`.
// A keyword is unambiguous in member position (only a member name is valid
// after a `.`), and several built-in methods use reserved spellings — the
// bitwise integer methods `and` / `or` / `xor` in particular.  The
// keyword's source spelling becomes the member name.
pub func tryEatMemberName(st: inout ParseState): Option[NameAndSpan] {
  val t = peek(st)
  match t.token {
    case TIdent(name) -> {
      st.pos = st.pos + 1
      Some(value = NameAndSpan(name = name, span = t.span))
    }
    case TKeyword(k) -> {
      st.pos = st.pos + 1
      Some(value = NameAndSpan(name = keywordSpelling(k), span = t.span))
    }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Span utilities.
// ─────────────────────────────────────────────────────────────────────────────

pub func joinSpans(a: in Span, b: in Span): Span {
  makeSpan(a.startPos, b.endPos)
}

pub func syntheticSpan(): Span {
  pointSpan(initialPosition())
}

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func emitErr(st: inout ParseState, code: in String, msg: in String, sp: in Span) {
  st.diags.add(errorDiagnostic(code, msg, sp))
}

pub func forceAdvanceIfStuck(st: inout ParseState, before: in Int) {
  if st.pos == before and not isAtEnd(st) {
    val _ = advance(st)
  }
}

// readIdent: like tryEatIdentOrContextual but emits P0103 on failure.
pub func readIdent(st: inout ParseState, whatFor: in String): NameAndSpan {
  match tryEatIdentOrContextual(st) {
    case Some(ns) -> ns
    case None -> {
      val sp = peekSpan(st)
      emitErr(st, "P0103", "expected an identifier for " + whatFor + " name", sp)
      NameAndSpan(name = "<error>", span = sp)
    }
  }
}

// mergeGenericsInfo: combine a prefix generic-params with a suffix one;
// report P0102 if both are present and return the prefix.
pub func mergeGenericsInfo(st: inout ParseState, prefix: in Option[GenericParams], suffix: in Option[GenericParams]): Option[GenericParams] {
  match prefix {
    case Some(p) -> {
      match suffix {
        case Some(s) -> {
          emitErr(st, "P0102", "generic[...] may appear before or after the name, not both", s.span)
          Some(value = p)
        }
        case None -> Some(value = p)
      }
    }
    case None -> suffix
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Module path: IDENT { '.' IDENT }
// ─────────────────────────────────────────────────────────────────────────────

pub func parseModulePath(st: inout ParseState): ModulePath {
  val segments: List[String] = newList()
  val initSp = peekSpan(st)
  var startP = initSp.startPos
  var endP   = initSp.endPos
  var haveStart = false

  match tryEatIdent(st) {
    case Some(ns) -> {
      startP = ns.span.startPos
      endP   = ns.span.endPos
      haveStart = true
      segments.add(ns.name)
    }
    case None -> {
      emitErr(st, "P0010", "expected an identifier in module path", peekSpan(st))
    }
  }

  var keepGoing = true
  while keepGoing {
    // Only continue past '.' when the token after it is also an identifier.
    val nextIsDotIdent =
      isPunct(peekToken(st), Dot) and
      (match peekAt(st, 1).token { case TIdent(_) -> true; case _ -> false })
    if nextIsDotIdent {
      val _ = advance(st)  // '.'
      match tryEatIdent(st) {
        case Some(ns) -> {
          if not haveStart {
            startP = ns.span.startPos
            haveStart = true
          }
          endP = ns.span.endPos
          segments.add(ns.name)
        }
        case None -> { keepGoing = false }
      }
    } else {
      keepGoing = false
    }
  }

  ModulePath(segments = segments, span = makeSpan(startP, endP))
}

// ─────────────────────────────────────────────────────────────────────────────
// Annotations.
// ─────────────────────────────────────────────────────────────────────────────

func parseAnnotationArg(st: inout ParseState): AnnotationArg {
  val startSp = peekSpan(st)
  match peekToken(st) {
    case TIdent(name) -> {
      val nameTok = advance(st)
      if isPunct(peekToken(st), Eq) {
        val _ = advance(st)  // '='
        val valueTok = advance(st)
        val value = match valueTok.token {
          case TInt(v, _)    -> AVInt(value = v, span = valueTok.span)
          case TString(s)    -> AVString(value = s, span = valueTok.span)
          case TBool(b)      -> AVBool(value = b, span = valueTok.span)
          case TIdent(id)    -> AVIdent(value = id, span = valueTok.span)
          case _ -> {
            emitErr(st, "P0011", "expected a literal or identifier as annotation value", valueTok.span)
            AVIdent(value = "<error>", span = valueTok.span)
          }
        }
        val endSp = match value {
          case AVInt(_, s)    -> s
          case AVString(_, s) -> s
          case AVBool(_, s)   -> s
          case AVIdent(_, s)  -> s
        }
        AAName(name = name, value = value, span = joinSpans(nameTok.span, endSp))
      } else {
        ABare(name = name, span = startSp)
      }
    }
    case TInt(v, _) -> {
      val t = advance(st)
      ALiteral(value = AVInt(value = v, span = t.span), span = t.span)
    }
    case TString(s) -> {
      val t = advance(st)
      ALiteral(value = AVString(value = s, span = t.span), span = t.span)
    }
    case TBool(b) -> {
      val t = advance(st)
      ALiteral(value = AVBool(value = b, span = t.span), span = t.span)
    }
    case _ -> {
      emitErr(st, "P0011", "expected an annotation argument", startSp)
      val _ = advance(st)
      ALiteral(value = AVIdent(value = "<error>", span = startSp), span = startSp)
    }
  }
}

pub func parseAnnotation(st: inout ParseState): Option[Annotation] {
  if not isPunct(peekToken(st), At) {
    None
  } else {
    cstStart(st, SkAnnotation)
    val atTok = advance(st)
    val name = parseModulePath(st)
    val args: List[AnnotationArg] = newList()
    var endSpan = name.span
    if isPunct(peekToken(st), LParen) {
      val _ = advance(st)
      if not isPunct(peekToken(st), RParen) {
        args.add(parseAnnotationArg(st))
        var keepGoing = true
        while keepGoing {
          if isPunct(peekToken(st), Comma) {
            val _ = advance(st)
            if not isPunct(peekToken(st), RParen) {
              args.add(parseAnnotationArg(st))
            }
          } else {
            keepGoing = false
          }
        }
      }
      match tryEatPunct(st, RParen) {
        case Some(t) -> { endSpan = t.span }
        case None -> {
          emitErr(st, "P0012", "expected ')' to close annotation argument list", peekSpan(st))
        }
      }
    }
    val result = Some(value = Annotation(name = name, args = args, span = joinSpans(atTok.span, endSpan)))
    cstFinish(st)
    result
  }
}

pub func parseItemAnnotations(st: inout ParseState): List[Annotation] {
  val xs: List[Annotation] = newList()
  var keepGoing = true
  while keepGoing {
    match parseAnnotation(st) {
      case Some(a) -> {
        xs.add(a)
        val _ = skipStmtEnds(st)
      }
      case None -> { keepGoing = false }
    }
  }
  xs
}

pub func parseTrailingAnnotations(st: inout ParseState): List[Annotation] {
  val xs: List[Annotation] = newList()
  var keepGoing = true
  while keepGoing {
    match parseAnnotation(st) {
      case Some(a) -> { xs.add(a) }
      case None -> { keepGoing = false }
    }
  }
  xs
}

pub func parseFileLevelAnnotations(st: inout ParseState): List[Annotation] {
  cstStart(st, SkFileAnnotationsSection)
  val _ = skipStmtEnds(st)
  val xs: List[Annotation] = newList()
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    match parseAnnotation(st) {
      case Some(a) -> { xs.add(a) }
      case None -> { keepGoing = false }
    }
  }
  cstFinish(st)
  xs
}

// ─────────────────────────────────────────────────────────────────────────────
// Doc-comment harvesting.
// ─────────────────────────────────────────────────────────────────────────────

pub func parseModuleDocComments(st: inout ParseState): List[DocComment] {
  cstStart(st, SkModuleDocSection)
  val _ = skipStmtEnds(st)
  val xs: List[DocComment] = newList()
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    match peekToken(st) {
      case TModuleDocComment(text) -> {
        val sp = peekSpan(st)
        val _ = advance(st)
        xs.add(DocComment(isModule = true, text = text, span = sp))
      }
      case _ -> { keepGoing = false }
    }
  }
  cstFinish(st)
  xs
}

pub func parseItemDocComments(st: inout ParseState): List[DocComment] {
  val xs: List[DocComment] = newList()
  var keepGoing = true
  while keepGoing {
    match peekToken(st) {
      case TDocComment(text) -> {
        val sp = peekSpan(st)
        val _ = advance(st)
        xs.add(DocComment(isModule = false, text = text, span = sp))
        val _ = skipStmtEnds(st)
      }
      case _ -> { keepGoing = false }
    }
  }
  xs
}

// ─────────────────────────────────────────────────────────────────────────────
// Package declaration and imports.
// ─────────────────────────────────────────────────────────────────────────────

pub func parsePackageDecl(st: inout ParseState): PackageDecl {
  val _ = skipStmtEnds(st)
  cstStart(st, SkPackageDecl)
  val result = match tryEatKw(st, KwPackage) {
    case Some(pkgTok) -> {
      val path = parseModulePath(st)
      PackageDecl(path = path, span = joinSpans(pkgTok.span, path.span))
    }
    case None -> {
      // Suppress the error for a truly empty file — silence is appropriate
      // when there's no content at all.  Non-empty files missing 'package'
      // still get P0020.
      if not isAtEnd(st) {
        // A leading `///` (item/outer doc) before `package` has no item to
        // attach to — `parseModuleDocComments` only harvests `//!`
        // (module/inner docs), so the `///` is left in the stream and lands
        // here.  Point the author at `//!` rather than the misleading bare
        // "expected 'package'" message (the package usually IS present, just
        // after the stray doc comment).
        val msg = match peekToken(st) {
          case TDocComment(_) ->
            "a '///' doc comment before 'package' has no item to document; " +
            "use '//!' for a module-level doc comment"
          case _ ->
            "expected 'package' declaration at the head of the file"
        }
        emitErr(st, "P0020", msg, peekSpan(st))
      }
      val sp = peekSpan(st)
      val emptySegs: List[String] = newList()
      PackageDecl(path = ModulePath(segments = emptySegs, span = sp), span = sp)
    }
  }
  cstFinish(st)
  result
}

func parseImportItem(st: inout ParseState): ImportItem {
  val nameTok = peek(st)
  val ns = match tryEatIdent(st) {
    case Some(n) -> n
    case None -> {
      emitErr(st, "P0030", "expected identifier in import group", nameTok.span)
      NameAndSpan(name = "<error>", span = nameTok.span)
    }
  }
  match tryEatKw(st, KwAs) {
    case Some(_) -> {
      match tryEatIdent(st) {
        case Some(al) -> {
          ImportItem(name = ns.name, asAlias = Some(value = al.name),
                     span = joinSpans(ns.span, al.span))
        }
        case None -> {
          emitErr(st, "P0031", "expected identifier after 'as' in import group", peekSpan(st))
          ImportItem(name = ns.name, asAlias = None, span = ns.span)
        }
      }
    }
    case None -> ImportItem(name = ns.name, asAlias = None, span = ns.span)
  }
}

func parseImportDecl(st: inout ParseState): Option[ImportDecl] {
  val isPubUse =
    isKw(peekToken(st), KwPub) and isKw(peekAt(st, 1).token, KwUse)
  val isImport = isKw(peekToken(st), KwImport)
  if not isImport and not isPubUse {
    None
  } else {
    cstStart(st, SkImportDecl)
    val startSp = peekSpan(st)
    if isPubUse {
      val _ = advance(st)  // pub
      val _ = advance(st)  // use
    } else {
      val _ = advance(st)  // import
    }
    val path = parseModulePath(st)

    // Optional `.{...}` group selector.
    val selector: Option[ImportSelector] =
      if isPunct(peekToken(st), Dot) and isPunct(peekAt(st, 1).token, LBrace) {
        val _ = advance(st)  // '.'
        val _ = advance(st)  // '{'
        val items: List[ImportItem] = newList()
        if not isPunct(peekToken(st), RBrace) {
          items.add(parseImportItem(st))
          var keepGoing = true
          while keepGoing {
            if isPunct(peekToken(st), Comma) {
              val _ = advance(st)
              if not isPunct(peekToken(st), RBrace) {
                items.add(parseImportItem(st))
              }
            } else {
              keepGoing = false
            }
          }
        }
        match tryEatPunct(st, RBrace) {
          case Some(_) -> {}
          case None -> {
            emitErr(st, "P0032", "expected '}' to close import group", peekSpan(st))
          }
        }
        Some(value = ISGroup(items = items))
      } else {
        None
      }

    var endSp = path.span
    val result = match tryEatKw(st, KwAs) {
      case Some(_) -> {
        match tryEatIdent(st) {
          case Some(al) -> {
            endSp = al.span
            Some(value = ImportDecl(path = path, selector = selector,
                                    asAlias = Some(value = al.name),
                                    isPubUse = isPubUse,
                                    span = joinSpans(startSp, endSp)))
          }
          case None -> {
            emitErr(st, "P0033", "expected identifier after 'as' in import", peekSpan(st))
            Some(value = ImportDecl(path = path, selector = selector,
                                    asAlias = None, isPubUse = isPubUse,
                                    span = joinSpans(startSp, endSp)))
          }
        }
      }
      case None -> {
        Some(value = ImportDecl(path = path, selector = selector,
                                asAlias = None, isPubUse = isPubUse,
                                span = joinSpans(startSp, endSp)))
      }
    }
    cstFinish(st)
    result
  }
}

pub func parseImports(st: inout ParseState): List[ImportDecl] {
  cstStart(st, SkImportSection)
  val _ = skipStmtEnds(st)
  val xs: List[ImportDecl] = newList()
  var keepGoing = true
  while keepGoing {
    val _ = skipStmtEnds(st)
    match parseImportDecl(st) {
      case Some(d) -> { xs.add(d) }
      case None -> { keepGoing = false }
    }
  }
  cstFinish(st)
  xs
}
