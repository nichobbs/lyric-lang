// fmt/fmt.l — top-level entry points for the self-hosted Lyric formatter.
//
// `format(parsed)` walks the AST to produce canonical Lyric source, mirroring
// the F# bootstrap formatter at `compiler/src/Lyric.Cli/Fmt.fs`, and uses the
// red/green CST attached to `ParseResult` (Phase 5 §M5.1 stage 5′) to
// preserve line and block comments at item boundaries — the comments today's
// F# `lyric fmt` drops.  Item-internal comment preservation (inside function
// bodies, record fields, etc.) is intentionally deferred until the CST is
// refined to per-statement / per-expression granularity.
//
// Public API (matches the Future-package contract advertised in
// compiler/lyric/lyric/cli.l):
//
//     pub func format(parsed: in ParseResult): String
//     pub func isFormatted(source: in String, parsed: in ParseResult): Bool
package Lyric.Fmt

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Comment harvesting from the green CST.  We collect every line and
// block-comment trivium and store it with its source offset so the formatter
// can replay them at the appropriate item boundary.  The list is in source
// order because the CST visit is in source order.
// ─────────────────────────────────────────────────────────────────────────────

record HarvestedComment {
  text:   String     // includes the `//` or `/* */` prefix verbatim
  offset: Int        // byte offset into the (CR/LF-normalised) source
}

/// Pretty-printer state.  The harvested comment list is sorted by
/// source offset (the CST traversal visits tokens in document order),
/// and `cursor` points at the next un-emitted comment.  Multi-line
/// printers thread `ctx: inout FmtCtx` so they can pop pending
/// comments at every structural boundary (top-level item, statement,
/// record / union / enum member).  Inline printers don't take it
/// because nothing emits across multiple source lines.
pub record FmtCtx {
  comments: List[HarvestedComment]
  cursor:   Int
}

pub func newFmtCtx(comments: in List[HarvestedComment]): FmtCtx {
  FmtCtx(comments = comments, cursor = 0)
}

/// Pop every comment whose offset is `< hi` from the front of
/// `ctx.cursor` and render the runs as `Doc` lines.  Block comments
/// retain their internal newlines (split on `\n` so each rendered
/// line is one source line).
pub func popCommentsBefore(ctx: inout FmtCtx, hi: in Int): List[String] {
  val acc: List[String] = newList()
  while ctx.cursor < ctx.comments.count and ctx.comments[ctx.cursor].offset < hi {
    val text = ctx.comments[ctx.cursor].text
    val parts = Str.split(text, "\n")
    var j = 0
    while j < parts.length {
      acc.add(parts[j])
      j = j + 1
    }
    ctx.cursor = ctx.cursor + 1
  }
  acc
}

/// Skip past any comments with offset `< hi` without emitting them.
/// Used at the very start of a structural section when a higher-level
/// caller has already taken responsibility for a span.
pub func skipCommentsBefore(ctx: inout FmtCtx, hi: in Int): Unit {
  while ctx.cursor < ctx.comments.count and ctx.comments[ctx.cursor].offset < hi {
    ctx.cursor = ctx.cursor + 1
  }
}

func harvestCommentsFromToken(t: in SpannedToken, acc: inout List[HarvestedComment]): Unit {
  var i = 0
  while i < t.leadingTrivia.count {
    val tr = t.leadingTrivia[i]
    match tr.kind {
      case TKLineComment  -> acc.add(HarvestedComment(text = tr.text, offset = tr.span.startPos.offset))
      case TKBlockComment -> acc.add(HarvestedComment(text = tr.text, offset = tr.span.startPos.offset))
      case _ -> {}
    }
    i = i + 1
  }
}

func harvestCommentsFromNode(n: in GreenNode, acc: inout List[HarvestedComment]): Unit {
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcToken(t) -> harvestCommentsFromToken(t, acc)
      case GcNode(child) -> harvestCommentsFromNode(child, acc)
    }
    i = i + 1
  }
}

func harvestComments(cst: in GreenNode): List[HarvestedComment] {
  val acc: List[HarvestedComment] = newList()
  harvestCommentsFromNode(cst, acc)
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. CST navigation: locate the `SkItem` green nodes in document order so we
// can match them up with the AST `Item` list.  The CST and AST are built in
// lock-step by the parser, so the n-th `SkItem` corresponds to the n-th AST
// item.
// ─────────────────────────────────────────────────────────────────────────────

func collectItemNodes(n: in GreenNode, acc: inout List[GreenNode]): Unit {
  match n.kind {
    case SkItem -> { acc.add(n); return }
    case _      -> {}
  }
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcNode(child) -> collectItemNodes(child, acc)
      case GcToken(_)    -> {}
    }
    i = i + 1
  }
}

func itemNodes(cst: in GreenNode): List[GreenNode] {
  val acc: List[GreenNode] = newList()
  collectItemNodes(cst, acc)
  acc
}

/// Offset of the first token (real or via leading trivia) inside `n`.
/// Returns `-1` when the node is empty, which only occurs in error
/// recovery paths.
func nodeStartOffset(n: in GreenNode): Int {
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcToken(t) -> {
        if t.leadingTrivia.count > 0 {
          return t.leadingTrivia[0].span.startPos.offset
        }
        return t.span.startPos.offset
      }
      case GcNode(child) -> {
        val o = nodeStartOffset(child)
        if o >= 0 { return o }
      }
    }
    i = i + 1
  }
  -1
}

func nodeFirstTokenOffset(n: in GreenNode): Int {
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcToken(t)    -> { return t.span.startPos.offset }
      case GcNode(child) -> {
        val o = nodeFirstTokenOffset(child)
        if o >= 0 { return o }
      }
    }
    i = i + 1
  }
  -1
}

/// End offset of the last real (non-trivia) token in `n`, walking
/// children in reverse.  Used to bound the "between this item and the
/// next" comment range tightly: the item's AST `span.endPos` typically
/// points at the *next* token's start (parser emits `peekSpan` as the
/// item's end), which would zero out the inter-item range.
func nodeLastTokenEndOffset(n: in GreenNode): Int {
  var i = n.children.count - 1
  while i >= 0 {
    match n.children[i] {
      case GcToken(t)    -> {
        // Skip synthetic STMT_END tokens — their span is zero-width and
        // also at the next-token offset.  Real tokens have non-zero
        // span lengths.
        match t.token {
          case TStmtEnd -> {}
          case _ -> { return t.span.endPos.offset }
        }
      }
      case GcNode(child) -> {
        val o = nodeLastTokenEndOffset(child)
        if o >= 0 { return o }
      }
    }
    i = i - 1
  }
  -1
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Top-level `format`.  Mirrors `Lyric.Cli.Fmt.format` in F#, but
// threads `ctx: inout FmtCtx` through every multi-line printer so
// item-internal comments (between statements in a function body,
// between cases in a union, etc.) get woven in alongside the
// already-handled inter-item comments.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func format(parsed: in ParseResult): String {
  val file = parsed.file
  val cst  = parsed.cst
  val nodes = itemNodes(cst)
  var ctx  = newFmtCtx(harvestComments(cst))

  val sb: List[String] = newList()

  // Module-doc comments.
  var i = 0
  while i < file.moduleDoc.count {
    val d = file.moduleDoc[i]
    val prefix = if d.isModule { "//!" } else { "///" }
    if d.text == "" { sb.add(prefix) }
    else { sb.add(prefix + " " + d.text) }
    i = i + 1
  }

  // File-level annotations.
  i = 0
  while i < file.fileAnnotations.count {
    sb.add(annotationStr(file.fileAnnotations[i]))
    i = i + 1
  }

  // `package …`.
  sb.add("package " + pathStr(file.packageDecl.path))

  // The header (module doc + file annotations + package decl) ends at
  // the package decl's last token.  Skip past any harvested comments
  // that fall inside the header — they'd only be doc-comments which we
  // already emit via `file.moduleDoc`, but the cursor must move past
  // them so subsequent lookups stay honest.
  skipCommentsBefore(ctx, file.packageDecl.span.endPos.offset)

  // Imports.
  if file.imports.count > 0 {
    sb.add("")
    i = 0
    while i < file.imports.count {
      val imp = file.imports[i]
      // Comments before this import (e.g. an explanatory line comment).
      val pre = popCommentsBefore(ctx, imp.span.startPos.offset)
      var k = 0
      while k < pre.count { sb.add(pre[k]); k = k + 1 }
      val ds = importDoc(imp)
      var j = 0
      while j < ds.count { sb.add(ds[j]); j = j + 1 }
      i = i + 1
    }
  }

  // Items, with between-item AND item-internal comments preserved.
  if file.items.count > 0 {
    sb.add("")
    val n = file.items.count
    var idx = 0
    while idx < n {
      val item = file.items[idx]
      val itemStart =
        if idx < nodes.count { nodeFirstTokenOffset(nodes[idx]) }
        else                  { item.span.startPos.offset }

      // Comments between the previous item / header and this item's
      // first token (excluding any item-internal comments — those are
      // popped *during* `itemDoc` traversal).
      val between =
        popCommentsBefore(ctx, if itemStart >= 0 { itemStart } else { item.span.startPos.offset })
      if idx > 0 { sb.add("") }
      var k = 0
      while k < between.count { sb.add(between[k]); k = k + 1 }

      val ds = itemDoc(item, ctx)
      var j = 0
      while j < ds.count { sb.add(ds[j]); j = j + 1 }

      // After emitting the item, fast-forward the cursor past any
      // comments that still sit inside the item's source range — those
      // should have been consumed by the recursive `itemDoc`/`blockLines`
      // walk, but if a deeper construct is not yet ctx-aware (e.g. an
      // expression sub-tree), we don't want them re-emitting at the
      // next item boundary.
      val itemEnd =
        if idx < nodes.count {
          val o = nodeLastTokenEndOffset(nodes[idx])
          if o >= 0 { o } else { item.span.endPos.offset }
        } else {
          item.span.endPos.offset
        }
      skipCommentsBefore(ctx, itemEnd)
      idx = idx + 1
    }

    // Trailing comments after the last item.
    val tail = popCommentsBefore(ctx, parsed.source.length + 1)
    if tail.count > 0 {
      sb.add("")
      var k = 0
      while k < tail.count { sb.add(tail[k]); k = k + 1 }
    }
  } else {
    val tail = popCommentsBefore(ctx, parsed.source.length + 1)
    if tail.count > 0 {
      sb.add("")
      var k = 0
      while k < tail.count { sb.add(tail[k]); k = k + 1 }
    }
  }

  // Join with '\n', strip trailing whitespace per line.  Final newline.
  joinLines(sb)
}

func joinLines(lines: in List[String]): String {
  var acc = ""
  var i = 0
  while i < lines.count {
    acc = acc + Str.trimEnd(lines[i]) + "\n"
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. `isFormatted` — true when `source` already matches its canonical form.
// Mirrors the same helper in F# Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func isFormatted(source: in String, parsed: in ParseResult): Bool {
  val canonical = format(parsed)
  normaliseEnd(source) == normaliseEnd(canonical)
}

@pure
func normaliseEnd(s: in String): String {
  Str.trimEnd(Str.replace(s, "\r\n", "\n"))
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. String-in / string-out façade.  Convenience wrappers that
// internally drive `Lyric.Parser.parse` so callers (notably the F# CLI
// crossing the language boundary by reflection) don't need to construct
// a `ParseResult` themselves.  Mirrors the API contract advertised in
// `compiler/lyric/lyric/cli.l` for the eventual self-hosted CLI.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func formatSource(source: in String): String {
  format(parse(source))
}

@stable(since="0.1")
pub func isFormattedSource(source: in String): Bool {
  isFormatted(source, parse(source))
}
