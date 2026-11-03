//! resolve_nodeids.l - node identity (docs/70 §6.1, D325).
//!
//! The parser leaves every `nodeId` at 0.  `renumberNodeIds` gives every
//! expression, statement and pattern of a file (contract clauses and range
//! patterns included) a distinct id, dense from 1, after the syntactic
//! expansions, whatever generated the node.  A pass that rebuilds a node
//! leaves the new one at 0, so the numbering runs last and ids are never
//! carried across a rewrite.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ContractElaborator

ref record NodeCounter {
  var next: Int
}

pub record NumberedFile {
  file: SourceFile
  /// The number of nodes numbered: ids run from 1 to `count`.
  count: Int
}

func takeId(c: in NodeCounter): Int {
  c.next = c.next + 1
  c.next
}

/// `file` with every node numbered; post-order, so a node's id is greater
/// than its children's.
pub func renumberNodeIds(file: in SourceFile): NumberedFile {
  val c = NodeCounter(next = 0)
  val numbered = mapFileNodes(
    file,
    { e: Expr -> Expr(kind = e.kind, span = e.span, nodeId = takeId(c)) },
    { s: Statement -> Statement(kind = s.kind, span = s.span, nodeId = takeId(c)) },
    { p: Pattern -> Pattern(kind = p.kind, span = p.span, nodeId = takeId(c)) }
  )
  NumberedFile(file = numbered, count = c.next)
}

/// Every node id in `file`, in traversal order (a test and debugging aid).
pub func nodeIdsOf(file: in SourceFile): List[Int] {
  val ids: List[Int] = newList()
  mapFileNodes(
    file,
    { e: Expr -> ids.add(e.nodeId); e },
    { s: Statement -> ids.add(s.nodeId); s },
    { p: Pattern -> ids.add(p.nodeId); p }
  )
  ids
}
