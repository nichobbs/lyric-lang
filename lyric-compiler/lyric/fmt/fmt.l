//! fmt/fmt.l — top-level entry points for the self-hosted Lyric formatter.
//!
//! `format(parsed)` walks the AST to produce canonical Lyric source, mirroring
//! the F# bootstrap formatter at `compiler/src/Lyric.Cli/Fmt.fs`, and uses the
//! red/green CST attached to `ParseResult` (Phase 5 §M5.1 stage 5′) to
//! preserve line and block comments at item boundaries — the comments today's
//! F# `lyric fmt` drops.  Item-internal comment preservation (inside function
//! bodies, record fields, etc.) is intentionally deferred until the CST is
//! refined to per-statement / per-expression granularity.
//!
//! Public API (matches the Future-package contract advertised in
//! compiler/lyric/lyric/cli.l):
//!
//!     pub func format(parsed: in ParseResult): String
//!     pub func isFormatted(source: in String, parsed: in ParseResult): Bool
package Lyric.Fmt

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Trivia harvesting from the green CST.  We collect every line and
// block-comment trivium AND every "blank-line" marker (a run of two or
// more `TKNewline` trivia, optionally separated by `TKWhitespace`), each
// stored with its source offset so the formatter can replay them at the
// appropriate boundary.  The list is in source order because the CST
// visit is in source order.
// ─────────────────────────────────────────────────────────────────────────────
pub union HarvestedItem {
  /// A `//` or `/* */` comment.  `text` includes the leading prefix.
  /// `trailing` is true when the comment sat on the same source line as
  /// the preceding token (no newline between them) — i.e. an end-of-line
  /// comment that must be re-attached to the previous output line rather
  /// than emitted as a standalone leading line.
  case HiComment(text: String, offset: Int, trailing: Bool)
  /// One blank line in the original source (a run of 2+ consecutive
  /// `TKNewline` trivia).  Offset is the start of the run; multiple
  /// consecutive blank lines collapse to a single marker so the
  /// formatter never emits more than one blank line in a row.
  case HiBlank(offset: Int)
}

@pure
func harvestedOffset(h: in HarvestedItem): Int {
  match h {
    case HiComment(_, o, _) -> o
    case HiBlank(o) -> o
  }
}

/// Pretty-printer state.  The harvested trivia list is sorted by
/// source offset (the CST traversal visits tokens in document order),
/// and `cursor` points at the next un-emitted item.  Multi-line
/// printers thread `ctx: inout FmtCtx` so they can pop pending
/// trivia at every structural boundary (top-level item, statement,
/// record / union / enum member).  Inline printers don't take it
/// because nothing emits across multiple source lines.
pub record FmtCtx {
  items: List[HarvestedItem]
  cursor: Int
}

pub func newFmtCtx(items: in List[HarvestedItem]): FmtCtx {
  FmtCtx(items = items, cursor = 0)
}

/// Pop every item whose offset is `< hi` and render comments as `Doc`
/// lines and blank-line markers as empty strings.  Used inside blocks
/// and member lists so the formatter preserves intentional spacing
/// alongside comments.
pub func popTriviaBefore(ctx: inout FmtCtx, hi: in Int): List[String] {
  val acc: List[String] = newList()
  while ctx.cursor < ctx.items.count and harvestedOffset(ctx.items[ctx.cursor]) < hi {
    match ctx.items[ctx.cursor] {
      case HiComment(text, _, _) -> {
        val parts = Str.split(text, "\n")
        var j = 0
        while j < parts.length {
          acc.add(parts[j])
          j = j + 1
        }
      }
      case HiBlank(_) -> {
        acc.add("")
      }
    }
    ctx.cursor = ctx.cursor + 1
  }
  acc
}

/// Like `popTriviaBefore`, but emits directly into a caller-owned line
/// accumulator so that a *trailing* comment (one that sat on the same
/// source line as the preceding token) is re-attached to the previous
/// output line instead of being emitted as a standalone leading line.
/// Leading comments and blank-line markers are appended as new lines,
/// matching `popTriviaBefore`.  Used by the member / statement / arm
/// list printers (which build an un-indented accumulator that the caller
/// indents wholesale).
pub func appendTriviaInto(acc: inout List[String], ctx: inout FmtCtx, hi: in Int, dropBlanks: in Bool): Unit {
  while ctx.cursor < ctx.items.count and harvestedOffset(ctx.items[ctx.cursor]) < hi {
    match ctx.items[ctx.cursor] {
      case HiComment(text, _, trailing) -> {
        val parts = Str.split(text, "\n")
        if trailing and acc.count > 0 and acc[acc.count - 1] != "" and parts.length == 1 {
          acc[acc.count - 1] = acc[acc.count - 1] + "  " + parts[0]
        } else {
          var j = 0
          while j < parts.length {
            acc.add(parts[j])
            j = j + 1
          }
        }
      }
      case HiBlank(_) -> {
        if not dropBlanks {
          acc.add("")
        }
      }
    }
    ctx.cursor = ctx.cursor + 1
  }
}

/// Pop every comment whose offset is `< hi` and render as `Doc` lines.
/// Blank-line markers in the same range are silently dropped — used at
/// top-level item / import boundaries where the canonical formatter
/// already emits its own spacing rules.
pub func popCommentsBefore(ctx: inout FmtCtx, hi: in Int): List[String] {
  val acc: List[String] = newList()
  while ctx.cursor < ctx.items.count and harvestedOffset(ctx.items[ctx.cursor]) < hi {
    match ctx.items[ctx.cursor] {
      case HiComment(text, _, _) -> {
        val parts = Str.split(text, "\n")
        var j = 0
        while j < parts.length {
          acc.add(parts[j])
          j = j + 1
        }
      }
      case HiBlank(_) -> {
      }
    }
    ctx.cursor = ctx.cursor + 1
  }
  acc
}

/// Fast-forward past any trivia (comments and blanks) with offset
/// `< hi` without emission.  Used at item end to drop leftovers from
/// expression sub-trees that are not yet ctx-aware.
pub func skipCommentsBefore(ctx: inout FmtCtx, hi: in Int): Unit {
  while ctx.cursor < ctx.items.count and harvestedOffset(ctx.items[ctx.cursor]) < hi {
    ctx.cursor = ctx.cursor + 1
  }
}

func harvestTriviaFromToken(t: in SpannedToken, acc: inout List[HarvestedItem]): Unit {
  // `newlineRun` counts consecutive `TKNewline` trivia (whitespace
  // between newlines doesn't reset the run — `\n  \n` is still a
  // blank-line run).  `blankRecorded` ensures we emit at most one
  // `HiBlank` per run, no matter how many extra newlines follow.
  //
  // Lexer invariant: every whitespace / newline / non-doc-comment
  // trivium between two tokens is accumulated in
  // `state.pendingTrivia` and flushed atomically onto the *next*
  // token's `leadingTrivia` at `emit()` time (see
  // `compiler/lyric/lyric/lexer.l:takePendingTrivia`).  A blank-line
  // run therefore never straddles a token boundary, so the per-call
  // reset of `newlineRun` / `blankRecorded` here is sufficient.
  var newlineRun = 0
  var blankRecorded = false
  var runStart = 0
  var i = 0
  while i < t.leadingTrivia.count {
    val tr = t.leadingTrivia[i]
    match tr.kind {
      case TKNewline -> {
        if newlineRun == 0 {
          runStart = tr.span.startPos.offset
        }
        newlineRun = newlineRun + 1
        if newlineRun >= 2 and not blankRecorded {
          acc.add(HiBlank(offset = runStart))
          blankRecorded = true
        }
      }
      case TKWhitespace -> {
        // Doesn't break a newline run — `\n  \n` is still a blank
        // line, just with leading spaces on the empty line.
      }
      case TKLineComment -> {
        val isTrailing = newlineRun == 0
        newlineRun = 0
        blankRecorded = false
        acc.add(HiComment(text = tr.text, offset = tr.span.startPos.offset, trailing = isTrailing))
      }
      case TKBlockComment -> {
        val isTrailing = newlineRun == 0
        newlineRun = 0
        blankRecorded = false
        acc.add(HiComment(text = tr.text, offset = tr.span.startPos.offset, trailing = isTrailing))
      }
    }
    i = i + 1
  }
}

func harvestTriviaFromNode(n: in GreenNode, acc: inout List[HarvestedItem]): Unit {
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcToken(t) -> harvestTriviaFromToken(t, acc)
      case GcNode(child) -> harvestTriviaFromNode(child, acc)
    }
    i = i + 1
  }
}

func harvestTrivia(cst: in GreenNode): List[HarvestedItem] {
  val acc: List[HarvestedItem] = newList()
  harvestTriviaFromNode(cst, acc)
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
    case SkItem -> {
      acc.add(n)
      return
    }
    case _ -> {
    }
  }
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcNode(child) -> collectItemNodes(child, acc)
      case GcToken(_) -> {
      }
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
        if o >= 0 {
          return o
        }
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
      case GcToken(t) -> {
        return t.span.startPos.offset
      }
      case GcNode(child) -> {
        val o = nodeFirstTokenOffset(child)
        if o >= 0 {
          return o
        }
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
      case GcToken(t) -> {
        // Skip synthetic STMT_END tokens — their span is zero-width and
        // also at the next-token offset.  Real tokens have non-zero
        // span lengths.
        match t.token {
          case TStmtEnd -> {
          }
          case _ -> {
            return t.span.endPos.offset
          }
        }
      }
      case GcNode(child) -> {
        val o = nodeLastTokenEndOffset(child)
        if o >= 0 {
          return o
        }
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
@stable(since = "0.1")
pub func format(parsed: in ParseResult): String {
  val file = parsed.file
  val cst = parsed.cst
  val nodes = itemNodes(cst)
  var ctx = newFmtCtx(harvestTrivia(cst))

  val sb: List[String] = newList()

  // File-header comments that precede the `package` declaration.  The
  // language reference (§1.3) makes `//!` the canonical form for a
  // module-level doc block, so `lyric fmt` auto-fixes a plain `//`
  // (or stray `///`) header into `//!` rather than dropping it or
  // leaving it in a non-doc form that the AST discards.  Block comments
  // (`/* … */`) are left verbatim.  See `promoteModuleComment`.
  val preHeader = popCommentsBefore(ctx, file.packageDecl.span.startPos.offset)
  var ph = 0
  while ph < preHeader.count {
    sb.add(promoteModuleComment(preHeader[ph]))
    ph = ph + 1
  }

  // Module-doc comments.
  var i = 0
  while i < file.moduleDoc.count {
    val d = file.moduleDoc[i]
    val prefix = if d.isModule { "//!" } else { "///" }
    if d.text == "" {
      sb.add(prefix)
    } else {
      sb.add(prefix + " " + d.text)
    }
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

  // Any comment that still sits inside the `package` declaration's own
  // span — e.g. a trailing `// note` on the `package` line — is emitted
  // rather than skipped so no comment is lost.  Doc comments here were
  // already rendered above via `file.moduleDoc`; only plain trivia can
  // remain.
  val pkgTail = popCommentsBefore(ctx, file.packageDecl.span.endPos.offset)
  var pt = 0
  while pt < pkgTail.count {
    sb.add(pkgTail[pt])
    pt = pt + 1
  }

  // Imports.
  if file.imports.count > 0 {
    sb.add("")
    i = 0
    while i < file.imports.count {
      val imp = file.imports[i]
      // Comments before this import (e.g. an explanatory line comment).
      val pre = popCommentsBefore(ctx, imp.span.startPos.offset)
      var k = 0
      while k < pre.count {
        sb.add(pre[k])
        k = k + 1
      }
      val ds = importDoc(imp)
      var j = 0
      while j < ds.count {
        sb.add(ds[j])
        j = j + 1
      }
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
      val itemStart = if idx < nodes.count { nodeFirstTokenOffset(nodes[idx]) } else { item.span.startPos.offset }

      // Comments between the previous item / header and this item's
      // first token (excluding any item-internal comments — those are
      // popped *during* `itemDoc` traversal).
      val between = popCommentsBefore(ctx, if itemStart >= 0 { itemStart } else { item.span.startPos.offset })
      if idx > 0 {
        sb.add("")
      }
      var k = 0
      while k < between.count {
        sb.add(between[k])
        k = k + 1
      }

      val ds = itemDoc(item, ctx)
      var j = 0
      while j < ds.count {
        sb.add(ds[j])
        j = j + 1
      }

      // After emitting the item, fast-forward the cursor past any
      // comments that still sit inside the item's source range — those
      // should have been consumed by the recursive `itemDoc`/`blockLines`
      // walk, but if a deeper construct is not yet ctx-aware (e.g. an
      // expression sub-tree), we don't want them re-emitting at the
      // next item boundary.
      val itemEnd = if idx < nodes.count {
        val o = nodeLastTokenEndOffset(nodes[idx])
        if o >= 0 {
          o
        } else {
          item.span.endPos.offset
        }
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
      while k < tail.count {
        sb.add(tail[k])
        k = k + 1
      }
    }
  } else {
    val tail = popCommentsBefore(ctx, parsed.source.length + 1)
    if tail.count > 0 {
      sb.add("")
      var k = 0
      while k < tail.count {
        sb.add(tail[k])
        k = k + 1
      }
    }
  }

  // Join with '\n', strip trailing whitespace per line.  Final newline.
  joinLines(sb)
}

/// Auto-fix a pre-`package` header comment into the canonical module-doc
/// form `//!`.  In practice this only ever sees plain `//` lines: those
/// are the trivia that precede `package`.  A `///` before `package` is a
/// P0020 parse error (it has no item to document), so `--write` rejects
/// the file via `formatSourceChecked` before `format` is ever called —
/// the `///` normalisation here is a defensive fallback, not a supported
/// `--write` path.  A `//` line and an already-`//!` line normalise to
/// `//!`, preserving any text and alignment after the marker; block-comment
/// fragments and non-comment lines pass through untouched.
@pure
func promoteModuleComment(line: in String): String {
  var i = 0
  while i < line.length and (line[i] == ' ' or line[i] == '\t') {
    i = i + 1
  }
  // Must begin with `//`; otherwise (block-comment body, blank) leave as-is.
  if i + 1 >= line.length or line[i] != '/' or line[i + 1] != '/' {
    return line
  }
  val ws = Str.substring(line, 0, i)
  var j = i
  while j < line.length and line[j] == '/' {
    j = j + 1
  }
  if j < line.length and line[j] == '!' {
    j = j + 1
  }
  val rest = Str.substring(line, j, line.length - j)
  ws + "//!" + rest
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
@stable(since = "0.1")
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
// internally drive `Lyric.Parser.parse` so callers don't need to
// construct a `ParseResult` themselves.  `lyric fmt` calls these from
// the self-hosted CLI dispatcher (`cli.l`, D-progress-260); the F#
// `SelfHostedBridge.fs` test harness also reaches them by reflection
// across the language boundary.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub func formatSource(source: in String): String {
  format(parse(source))
}

@stable(since = "0.1")
pub func isFormattedSource(source: in String): Bool {
  isFormatted(source, parse(source))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Loss-checked formatting.  `formatSourceChecked` formats a source
// string and then PROVES the result is lossless before returning it:
//
//   1. the input must parse without error diagnostics,
//   2. the formatted output must re-parse without error diagnostics,
//   3. every comment / doc-comment payload in the input must survive in
//      the output (marker-agnostic, so the `//` → `//!` module-comment
//      auto-fix does not count as a loss), and
//   4. the sequence of CODE tokens (everything but whitespace, comments,
//      commas, statement-end, and EOF) must be IDENTICAL — so a dropped
//      `pub`, a dropped `requires:` clause, a mangled `\u{…}` escape, or
//      an inserted `{ }` block that rescopes a binding is all refused.
//
// `lyric fmt --write` routes through this so it can never silently change
// a file's meaning: on any failure it refuses to overwrite and reports
// the reason, leaving the file untouched.
// ─────────────────────────────────────────────────────────────────────────────
pub union FmtCheck {
  /// Formatting succeeded and was proven lossless.
  case FmtOk(text: String)
  /// The input source has parse errors; it is not safe to reformat.
  case FmtInputParseError(diagnostics: List[Diagnostic])
  /// The formatted output failed to re-parse — a formatter bug.
  case FmtOutputParseError(diagnostics: List[Diagnostic])
  /// One or more comment payloads present in the input are absent from
  /// the formatted output.
  case FmtCommentLoss(dropped: List[String])
  /// The code-token sequence changed between input and output — a token
  /// was dropped, added, or reordered (so the formatter altered meaning,
  /// not just layout).  `detail` describes the first divergence.
  case FmtStructureChanged(detail: String)
}

@stable(since = "0.1")
pub func formatSourceChecked(source: in String): FmtCheck {
  val parsedIn = parse(source)
  val inErrs = errorDiagnostics(parsedIn.diagnostics)
  if inErrs.count > 0 {
    return FmtInputParseError(diagnostics = inErrs)
  }

  val formatted = format(parsedIn)

  val parsedOut = parse(formatted)
  val outErrs = errorDiagnostics(parsedOut.diagnostics)
  if outErrs.count > 0 {
    return FmtOutputParseError(diagnostics = outErrs)
  }

  val droppedComments = multisetMissing(commentPayloads(source), commentPayloads(formatted))
  if droppedComments.count > 0 {
    return FmtCommentLoss(dropped = droppedComments)
  }

  val structDiff = structuralSequenceDiff(parsedIn.source, formatted)
  if structDiff != "" {
    return FmtStructureChanged(detail = structDiff)
  }

  FmtOk(text = formatted)
}

func errorDiagnostics(ds: in List[Diagnostic]): List[Diagnostic] {
  val acc: List[Diagnostic] = newList()
  var i = 0
  while i < ds.count {
    match ds[i].severity {
      case DiagError -> acc.add(ds[i])
      case DiagWarning -> {
      }
    }
    i = i + 1
  }
  acc
}

/// The ordered code tokens of `source`: every lexed token's source text,
/// excluding whitespace/newline trivia (never tokens), statement-end and
/// EOF sentinels, doc/line/block comments, and commas.  Token text is
/// sliced from the (CR/LF-normalised) source by span so punctuation,
/// keywords, identifiers, and literals all compare by their exact
/// spelling without a per-kind spelling table.  Commas are excluded so
/// the "magic trailing comma" the formatter may add when breaking a list
/// across lines is not flagged as a change (a comma that truly separated
/// two items cannot vanish without breaking the re-parse, caught above).
func codeTokens(source: in String): List[String] {
  val lr = lex(source)
  val acc: List[String] = newList()
  var i = 0
  while i < lr.tokens.count {
    val t = lr.tokens[i]
    val include = match t.token {
      case TStmtEnd -> false
      case TEof -> false
      case TDocComment(_) -> false
      case TModuleDocComment(_) -> false
      case _ -> true
    }
    if include {
      val st = t.span.startPos.offset
      val en = t.span.endPos.offset
      val text = if en > st and st >= 0 and en <= source.length {
        Str.substring(source, st, en - st)
      } else {
        tokenKindTag(t.token)
      }
      if text != "," {
        acc.add(text)
      }
    }
    i = i + 1
  }
  acc
}

@pure
func tokenKindTag(tok: in Token): String {
  match tok {
    case TKeyword(kw) -> "kw:" + keywordSpelling(kw)
    case TIdent(name) -> "id:" + name
    case TString(s) -> "s:" + s
    case TBool(b) -> if b { "true" } else { "false" }
    case _ -> "<tok>"
  }
}

/// Compare the code-token sequences of two sources.  Returns "" when they
/// are identical, otherwise a one-line description of the first
/// divergence (1-based token index and the differing texts).
func structuralSequenceDiff(a: in String, b: in String): String {
  val ta = codeTokens(a)
  val tb = codeTokens(b)
  val n = if ta.count < tb.count { ta.count } else { tb.count }
  var i = 0
  while i < n {
    if ta[i] != tb[i] {
      return "token " + toString(i + 1) + " changed: `" + ta[i] + "` -> `" + tb[i] + "`"
    }
    i = i + 1
  }
  if ta.count != tb.count {
    return "token count changed: " + toString(ta.count) + " -> " + toString(tb.count)
  }
  ""
}

/// True when the checked format succeeded losslessly.
@stable(since = "0.1")
pub func fmtCheckIsOk(c: in FmtCheck): Bool {
  match c {
    case FmtOk(_) -> true
    case _ -> false
  }
}

/// The formatted text — valid only when `fmtCheckIsOk` is true (empty
/// string otherwise).
@stable(since = "0.1")
pub func fmtCheckText(c: in FmtCheck): String {
  match c {
    case FmtOk(t) -> t
    case _ -> ""
  }
}

/// A human-readable explanation of why a checked format was refused, or
/// the empty string on success.  Drives the `lyric fmt` diagnostic.
@stable(since = "0.1")
pub func fmtCheckMessage(c: in FmtCheck): String {
  match c {
    case FmtOk(_) -> ""
    case FmtInputParseError(ds) -> "fmt skipped — source has " + toString(ds.count) + " parse error(s); not safe to reformat:\n" + diagsMessage(ds)
    case FmtOutputParseError(ds) -> "fmt aborted — formatter output does not parse (" + toString(ds.count) + " error(s)); file left unchanged (formatter bug):\n" + diagsMessage(ds)
    case FmtCommentLoss(dropped) -> "fmt aborted — would drop " + toString(dropped.count) + " comment(s); file left unchanged:\n" + droppedMessage(dropped)
    case FmtStructureChanged(detail) -> "fmt aborted — formatting would change the code-token sequence " + "(formatter bug); file left unchanged:\n  " + detail
  }
}

func diagsMessage(ds: in List[Diagnostic]): String {
  var s = ""
  var i = 0
  while i < ds.count {
    val d = ds[i]
    s = s + "  " + d.code + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) + "]: " +
      d.message +
      "\n"
    i = i + 1
  }
  s
}

func droppedMessage(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count and i < 10 {
    s = s + "  - " + xs[i] + "\n"
    i = i + 1
  }
  if xs.count > 10 {
    s = s + "  ... and " + toString(xs.count - 10) + " more\n"
  }
  s
}

/// Collapse internal whitespace runs and strip the comment marker so two
/// comments compare equal modulo reflow and the `//` → `//!` auto-fix.
@pure
func normComment(raw: in String): String {
  var s = Str.trim(raw)
  if Str.startsWith(s, "/*") {
    s = Str.substring(s, 2, s.length - 2)
    if Str.endsWith(s, "*/") {
      s = Str.substring(s, 0, s.length - 2)
    }
  } else {
    var k = 0
    while k < s.length and s[k] == '/' {
      k = k + 1
    }
    if k < s.length and s[k] == '!' {
      k = k + 1
    }
    s = Str.substring(s, k, s.length - k)
  }
  collapseWs(Str.trim(s))
}

@pure
func collapseWs(s: in String): String {
  val noTabs = Str.replace(s, "\t", " ")
  val parts = Str.split(noTabs, " ")
  val acc: List[String] = newList()
  var i = 0
  while i < parts.length {
    if parts[i] != "" {
      acc.add(parts[i])
    }
    i = i + 1
  }
  joinStrings(acc, " ")
}

/// Every comment and doc-comment payload in `source`, normalised and with
/// empties dropped, in document order.
func commentPayloads(source: in String): List[String] {
  val lr = lex(source)
  val acc: List[String] = newList()
  var i = 0
  while i < lr.tokens.count {
    val t = lr.tokens[i]
    var k = 0
    while k < t.leadingTrivia.count {
      val tr = t.leadingTrivia[k]
      match tr.kind {
        case TKLineComment -> {
          val p = normComment(tr.text)
          if p != "" {
            acc.add(p)
          }
        }
        case TKBlockComment -> {
          val p = normComment(tr.text)
          if p != "" {
            acc.add(p)
          }
        }
        case TKWhitespace -> {
        }
        case TKNewline -> {
        }
      }
      k = k + 1
    }
    match t.token {
      case TDocComment(txt) -> {
        val p = normComment(txt)
        if p != "" {
          acc.add(p)
        }
      }
      case TModuleDocComment(txt) -> {
        val p = normComment(txt)
        if p != "" {
          acc.add(p)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  acc
}

/// Multiset difference `a \ b`: every element of `a` that appears more
/// often in `a` than in `b`, with the surplus multiplicity.
func multisetMissing(a: in List[String], b: in List[String]): List[String] {
  val missing: List[String] = newList()
  var i = 0
  while i < a.count {
    val v = a[i]
    var seen = false
    var p = 0
    while p < i {
      if a[p] == v {
        seen = true
      }
      p = p + 1
    }
    if not seen {
      var d = countOf(a, v) - countOf(b, v)
      while d > 0 {
        missing.add(v)
        d = d - 1
      }
    }
    i = i + 1
  }
  missing
}

func countOf(xs: in List[String], v: in String): Int {
  var c = 0
  var i = 0
  while i < xs.count {
    if xs[i] == v {
      c = c + 1
    }
    i = i + 1
  }
  c
}
