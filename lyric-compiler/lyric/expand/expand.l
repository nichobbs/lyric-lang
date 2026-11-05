//! expand.l - Lyric.Expand
//!
//! Support shared by the declaration-expansion passes (derives, the weaver;
//! docs/70 section 7.1, D370): they run before the checker, so what they
//! generate is checked like user code, and the checker's span-keyed side
//! tables (`spanKey`) need every generated node to carry a span of its own.
//!
//! A generated node takes a span from a `SpanAllocator`: a unique offset beyond
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

/// Hands out the offsets of generated spans. `next` is the offset the next
/// span takes.
pub record SpanAllocator {
  var next: Int
}

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

/// An allocator whose spans lie beyond every span of `file`.
pub func newSpanAllocator(file: in SourceFile): SpanAllocator {
  SpanAllocator(next = maxOffset(file) + 1)
}

/// The key under which `origins` records a generated span.
pub func generatedSpanKey(sp: in Span): String {
  spanKey(sp)
}

/// A fresh span for a node generated because of the declaration at `cause`;
/// records `cause` as its origin.
func freshSpan(alloc: in SpanAllocator, cause: in Span, origins: in Map[String, Span]): Span {
  val n = alloc.next
  alloc.next = n + 2
  val fid = cause.startPos.fileId
  val sp = Span(
    startPos = Position(offset = n, line = cause.startPos.line, column = cause.startPos.column, fileId = fid),
    endPos = Position(offset = n + 1, line = cause.startPos.line, column = cause.startPos.column, fileId = fid)
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
  alloc: in SpanAllocator,
  cause: in Span,
  origins: in Map[String, Span],
): List[Item] {
  val mapped = mapFileNodes(
    file.copy(items = items),
    { e: Expr -> e.copy(span = freshSpan(alloc, cause, origins)) },
    { s: Statement -> s.copy(span = freshSpan(alloc, cause, origins)) },
    { p: Pattern -> p.copy(span = freshSpan(alloc, cause, origins)) }
  )
  val out: List[Item] = newList()
  for it in mapped.items {
    val sp = freshSpan(alloc, cause, origins)
    match it.kind {
      case IFunc(d) -> out.add(it.copy(kind = IFunc(decl = respanFunc(d, sp)), span = sp))
      case _ -> out.add(it.copy(span = sp))
    }
  }
  out
}

/// `diags` with a diagnostic found in generated code (its span a key of
/// `origins`) reported at the declaration that caused the code, and a
/// warning there dropped: the user cannot fix generated code, so only an
/// error surfaces.
pub func relocateDiagnostics(origins: in Map[String, Span], diags: in List[Diagnostic]): List[Diagnostic] {
  if origins.count == 0 {
    return diags
  }
  val out: List[Diagnostic] = newList()
  for d in diags {
    match mapGet(origins, spanKey(d.span)) {
      case Some(cause) -> {
        if d.severity == DiagError {
          out.add(d.copy(span = cause, message = d.message + " (in code generated for this declaration)"))
        }
      }
      case None -> out.add(d)
    }
  }
  out
}
