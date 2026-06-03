// parser_cst.l — concrete syntax tree (Roslyn-style red/green) for the
// self-hosted Lyric.Parser.  The lexer captures whitespace, newlines,
// and non-doc comments as `Trivia` attached to each `SpannedToken`'s
// `leadingTrivia`; this file adds the structural tree on top so a
// downstream consumer (a formatter, an LSP, refactoring tools) sees
// both the parsed shape and the lossless original byte sequence.
//
// The CST is intentionally coarse-grained for the M5.1 stage 5'
// foundation: the parser only opens nodes at the file / package /
// import / item granularity (see `parser_items.l`).  Inside an item,
// every consumed token still appears as a token leaf of the item
// node, in the order the lexer produced it.  Future passes can
// refine the granularity (expression, statement, contract clause,
// etc.) without changing the data model.
//
// Design choice: events carry `tokenStart` / `tokenEnd` indices into
// the lexer's token list rather than buffering tokens themselves.
// `mark` / `reset` therefore do not need to truncate event history
// — internal speculation moves `st.pos` forward and back, but only
// the final span between an opening `CeStart` and matching
// `CeFinish` shows up in the green tree.
package Lyric.Parser

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// Syntax kinds.  Tokens are not enumerated here — they appear as
// `GcToken` leaves directly.  Adding a kind is forward-compatible:
// existing consumers fall through to a default in their `match`.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union SyntaxKind {
  case SkSourceFile
  case SkModuleDocSection
  case SkFileAnnotationsSection
  case SkPackageDecl
  case SkImportSection
  case SkImportDecl
  case SkItemSection
  case SkItem
  case SkAnnotation
  /// A `{ … }` block — function body, lambda body, control-flow body.
  /// Children are an opening `{` token, zero or more `SkStatement`
  /// nodes interleaved with `TStmtEnd` separator tokens, and a
  /// closing `}` token.
  case SkBlock
  /// A single statement inside a block.  The kind covers `val` / `var`
  /// / `let` bindings, `return`, `break`, `continue`, `throw`, `try`
  /// / `defer` / `scope` / `for` / `while` / `loop` / `invariant`
  /// statements, and bare expression statements.  An expression
  /// statement contains an `SkExpr` child for the expression itself.
  case SkStatement
  /// An expression node.  `parseExpr` is recursive through precedence
  /// climbers, but only the top of each `parseExpr` call wraps this
  /// node — sub-expressions appear as nested `SkExpr` children when
  /// any operand is itself a recursive `parseExpr` call, plus token
  /// leaves for operator / punctuation tokens consumed at this level.
  case SkExpr
  /// A `requires:` / `ensures:` / `when:` / `decreases:` / `raises:`
  /// contract clause attached to a function or entry declaration.
  case SkContractClause
  /// Catch-all for nodes that have not been broken out into their
  /// own kind yet.  Carries no semantic meaning beyond "structurally
  /// distinct from its surroundings".
  case SkRaw
}

// ─────────────────────────────────────────────────────────────────────────────
// Green tree.  Immutable, no parent pointers, structurally shareable.
// `width` is the byte length of the source span the node covers
// (including each token's leading trivia).  Concatenating
// `nodeText` (with the original source as the text source) reproduces
// the source byte-for-byte.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union GreenChild {
  case GcToken(token: SpannedToken)
  case GcNode(node: GreenNode)
}

@stable(since="0.1")
pub record GreenNode {
  kind:     SyntaxKind
  children: List[GreenChild]
  width:    Int
}

@pure
@stable(since="0.1")
pub func tokenWidth(t: in SpannedToken): Int {
  // Token's source extent + every preceding trivium's extent.  The
  // trivia spans are guaranteed contiguous (lexer enforces it).
  var w = spanLength(t.span)
  var i = 0
  while i < t.leadingTrivia.count {
    w = w + spanLength(t.leadingTrivia[i].span)
    i = i + 1
  }
  w
}

@pure
@stable(since="0.1")
pub func childWidth(c: in GreenChild): Int {
  match c {
    case GcToken(t) -> tokenWidth(t)
    case GcNode(n)  -> n.width
  }
}

@stable(since="0.1")
pub func makeGreenNode(kind: in SyntaxKind, children: in List[GreenChild]): GreenNode {
  var w = 0
  var i = 0
  while i < children.count {
    w = w + childWidth(children[i])
    i = i + 1
  }
  GreenNode(kind = kind, children = children, width = w)
}

// ─────────────────────────────────────────────────────────────────────────────
// Red tree.  A lightweight wrapper that adds parent pointers and
// absolute source offsets without copying the green node.  Built
// lazily on demand by the formatter / LSP — `makeRedRoot` is the only
// entry point the parser needs to ship.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record RedNode {
  green:  GreenNode
  parent: Option[RedNode]
  offset: Int
}

@stable(since="0.1")
pub func makeRedRoot(g: in GreenNode): RedNode {
  RedNode(green = g, parent = None, offset = 0)
}

@stable(since="0.1")
pub func redChildren(r: in RedNode): List[RedChild] {
  val xs: List[RedChild] = newList()
  var i = 0
  var off = r.offset
  while i < r.green.children.count {
    val c = r.green.children[i]
    match c {
      case GcToken(t) -> {
        xs.add(RcToken(token = t, parent = Some(value = r), offset = off))
        off = off + tokenWidth(t)
      }
      case GcNode(n) -> {
        xs.add(RcNode(node = RedNode(green = n, parent = Some(value = r), offset = off)))
        off = off + n.width
      }
    }
    i = i + 1
  }
  xs
}

@stable(since="0.1")
pub union RedChild {
  case RcToken(token: SpannedToken, parent: Option[RedNode], offset: Int)
  case RcNode(node: RedNode)
}

// ─────────────────────────────────────────────────────────────────────────────
// Lossless source reconstruction.  Walks the green tree and pulls
// each token's text out of the original source string, sandwiching
// every trivium in front (using its captured `text`).  The result is
// byte-identical to the input source — modulo CRLF / CR normalisation
// performed by `lex` itself.
// ─────────────────────────────────────────────────────────────────────────────

@pure
@stable(since="0.1")
pub func tokenSourceText(source: in String, t: in SpannedToken): String {
  var s = ""
  var i = 0
  while i < t.leadingTrivia.count {
    s = s + t.leadingTrivia[i].text
    i = i + 1
  }
  val len = spanLength(t.span)
  if len > 0 {
    s = s + Str.substring(source, t.span.startPos.offset, len)
  }
  s
}

@pure
@stable(since="0.1")
pub func childSourceText(source: in String, c: in GreenChild): String {
  match c {
    case GcToken(t) -> tokenSourceText(source, t)
    case GcNode(n)  -> nodeSourceText(source, n)
  }
}

@pure
@stable(since="0.1")
pub func nodeSourceText(source: in String, n: in GreenNode): String {
  var s = ""
  var i = 0
  while i < n.children.count {
    s = s + childSourceText(source, n.children[i])
    i = i + 1
  }
  s
}

// ─────────────────────────────────────────────────────────────────────────────
// Event-based builder.  The parser pushes `CeStart` / `CeFinish`
// events into `ParseState.cstEvents` as it enters / exits each
// production; after parsing, `buildGreenTree` walks the events plus
// the lexer's token list to materialise the green tree.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union CstEvent {
  case CeStart(kind: SyntaxKind, tokenStart: Int)
  case CeFinish(tokenEnd: Int)
}

/// Materialise the green CST root from a sequence of well-formed
/// parse events plus the original token stream.  The algorithm is
/// streaming: a single `cursor` tracks the next token index that has
/// not yet been claimed by some node.  When a child opens at
/// `tokenStart > cursor`, the gap belongs to the parent as direct
/// token children; same when a frame closes at `tokenEnd > cursor`.
@stable(since="0.1")
pub func buildGreenTree(events: in List[CstEvent], tokens: in List[SpannedToken]): GreenNode {
  val stackKinds: List[SyntaxKind] = newList()
  val stackChildren: List[List[GreenChild]] = newList()
  var cursor = 0
  var rootNode: Option[GreenNode] = None

  var i = 0
  while i < events.count {
    match events[i] {
      case CeStart(kind, ts) -> {
        // Tokens in [cursor, ts) belong to the current top-of-stack
        // (if any); the gap may be empty.
        flushTokensToTop(stackChildren, tokens, cursor, ts)
        cursor = ts
        stackKinds.add(kind)
        val empty: List[GreenChild] = newList()
        stackChildren.add(empty)
      }
      case CeFinish(te) -> {
        flushTokensToTop(stackChildren, tokens, cursor, te)
        cursor = te
        val n = stackKinds.count
        val k = stackKinds[n - 1]
        val ch = stackChildren[n - 1]
        stackKinds.removeAt(n - 1)
        stackChildren.removeAt(n - 1)
        val node = makeGreenNode(k, ch)
        if stackChildren.count > 0 {
          val pn = stackChildren.count
          stackChildren[pn - 1].add(GcNode(node = node))
        } else {
          rootNode = Some(value = node)
        }
      }
    }
    i = i + 1
  }
  match rootNode {
    case Some(n) -> n
    case None -> {
      val empty: List[GreenChild] = newList()
      makeGreenNode(SkSourceFile, empty)
    }
  }
}

/// Append tokens in `[fromIdx, toIdx)` as token children of the
/// topmost frame, if any.  Caller is responsible for advancing the
/// cursor.  (`end` is a reserved keyword; the local clamp is named
/// `stopIdx`.)
func flushTokensToTop(stackChildren: inout List[List[GreenChild]],
                      tokens: in List[SpannedToken],
                      fromIdx: in Int,
                      toIdx: in Int): Unit {
  val n = stackChildren.count
  if n == 0 { return }
  val top = stackChildren[n - 1]
  var i = fromIdx
  val stopIdx = if toIdx <= tokens.count { toIdx } else { tokens.count }
  while i < stopIdx {
    top.add(GcToken(token = tokens[i]))
    i = i + 1
  }
}
