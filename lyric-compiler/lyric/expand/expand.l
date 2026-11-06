//! expand.l - Lyric.Expand
//!
//! Support shared by the declaration-expansion passes (derives, the weaver;
//! docs/70 section 7.1, D370): they run before the checker, so what they
//! generate is checked like user code, and the checker's span-keyed side
//! tables (`spanKey`) need every generated node to carry a span of its own.
//!
//! A generated node takes a unique offset beyond
//! the highest real offset of the package, with the line and column of the
//! declaration that caused it. `origins` maps each allocated span key back to
//! the span of that declaration, and `relocateDiagnostics` reports a
//! diagnostic found in generated code at the declaration instead. When the
//! checker's tables are keyed by `NodeId` the allocator goes away and a
//! generated node simply takes the cause's span.
package Lyric.Expand

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ContractElaborator

/// The highest offset any span of `file` ends at.
func maxOffset(file: in SourceFile): Int {
  var m = file.span.endPos.offset
  for it in file.items {
    if it.span.endPos.offset > m {
      m = it.span.endPos.offset
    }
  }
  for imp in file.imports {
    if imp.span.endPos.offset > m {
      m = imp.span.endPos.offset
    }
  }
  m
}

/// The first offset of generated spans for `file`: beyond every span of it. A
/// generated span takes `base + 2 * origins.count` (the map gains one entry
/// per span), so spans stay unique without a mutable counter.
pub func generatedSpanBase(file: in SourceFile): Int {
  maxOffset(file) + 1
}

/// The key under which `origins` records a generated span.
pub func generatedSpanKey(sp: in Span): String {
  spanKey(sp)
}

/// A fresh span for a node generated because of the declaration at `cause`;
/// records `cause` as its origin. With `keepSourceLines` a node that has a
/// source position of its own (advice copied from an aspect) keeps its line,
/// column and file, and a node without one takes the cause's line with column
/// 0, which `isGeneratedSpan` reads as "no line-table row". Without it every
/// node takes the cause's line and column.
func freshSpan(
  base: in Int, like: in Span, cause: in Span, origins: in Map[String, Span], keepSourceLines: in Bool
): Span {
  val n = base + 2 * origins.count
  val own = keepSourceLines and like.startPos.line > 0
  val src = if own { like } else { cause }
  val col = if keepSourceLines and not own { 0 } else { src.startPos.column }
  val fid = src.startPos.fileId
  val sp = Span(
    startPos = Position(offset = n, line = src.startPos.line, column = col, fileId = fid),
    endPos = Position(offset = n + 1, line = src.startPos.line, column = col, fileId = fid)
  )
  origins.add(spanKey(sp), cause)
  sp
}

func respanFunc(d: in FunctionDecl, sp: in Span): FunctionDecl {
  d.copy(span = sp)
}

/// `items`, generated because of the declaration at `cause`, with a fresh
/// span on every item, function and expression, statement and pattern in
/// them. `file` supplies the package context the traversal rebuilds
/// (only its items are replaced).
pub func respanGenerated(
  file: in SourceFile,
  items: in List[Item],
  base: in Int,
  cause: in Span,
  origins: in Map[String, Span],
  keepSourceLines: in Bool = false,
): List[Item] {
  val mapped = mapFileNodes(
    file.copy(items = items),
    { e: Expr -> e.copy(span = freshSpan(base, e.span, cause, origins, keepSourceLines)) },
    { s: Statement -> s.copy(span = freshSpan(base, s.span, cause, origins, keepSourceLines)) },
    { p: Pattern -> p.copy(span = freshSpan(base, p.span, cause, origins, keepSourceLines)) }
  )
  val res: List[Item] = newList()
  for it in mapped.items {
    val sp = freshSpan(base, it.span, cause, origins, keepSourceLines)
    match it.kind {
      case IFunc(d) -> res.add(it.copy(kind = IFunc(decl = respanFunc(d, sp)), span = sp))
      case _ -> res.add(it.copy(span = sp))
    }
  }
  res
}

/// `diags` with a diagnostic found in generated code (its span a key of
/// `origins`) reported at the declaration that caused the code, and a
/// warning there dropped: the user cannot fix generated code, so only an
/// error surfaces.
pub func relocateDiagnostics(origins: in Map[String, Span], diags: in List[Diagnostic]): List[Diagnostic] {
  if origins.count == 0 {
    return diags
  }
  val res: List[Diagnostic] = newList()
  for d in diags {
    match mapGet(origins, spanKey(d.span)) {
      case Some(cause) -> {
        if d.severity == DiagError {
          res.add(d.copy(span = cause, message = d.message + " (in code generated for this declaration)"))
        }
      }
      case None -> res.add(d)
    }
  }
  res
}

func shiftPos(p: in Position, delta: in Int): Position {
  p.copy(offset = p.offset + delta)
}

func shiftSpan(sp: in Span, delta: in Int): Span {
  Span(startPos = shiftPos(sp.startPos, delta), endPos = shiftPos(sp.endPos, delta))
}

/// `items`, parsed on their own from generated text, moved by `delta` offsets
/// so they sit beyond every span of the package they join: each node's offsets
/// move together, so spans still nest as they did in the parse, and a callee
/// path (which the checker keys a call's resolved callee by) is moved with its
/// expression.  `delta` must put the items beyond every offset of the file and
/// of the other items moved (docs/70 section 7.1).
pub func shiftGenerated(file: in SourceFile, items: in List[Item], delta: in Int): List[Item] {
  val mapped = mapFileNodes(
    file.copy(items = items),
    { e: Expr ->
      match e.kind {
        case EPath(p) -> e.copy(
          kind = EPath(path = p.copy(span = shiftSpan(p.span, delta))),
          span = shiftSpan(e.span, delta)
        )
        case _ -> e.copy(span = shiftSpan(e.span, delta))
      }
    },
    { s: Statement -> s.copy(span = shiftSpan(s.span, delta)) },
    { p: Pattern -> p.copy(span = shiftSpan(p.span, delta)) }
  )
  val res: List[Item] = newList()
  for it in mapped.items {
    val sp = shiftSpan(it.span, delta)
    match it.kind {
      case IFunc(d) -> res.add(it.copy(kind = IFunc(decl = d.copy(span = sp)), span = sp))
      case _ -> res.add(it.copy(span = sp))
    }
  }
  res
}
