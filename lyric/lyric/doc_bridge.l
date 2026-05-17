// doc_bridge.l — text-protocol bridge for the F# SelfHostedDoc.fs shim.
// Wraps Lyric.Doc.generate and returns the result via a simple prefix protocol
// so the F# shim does not need to reflect on Lyric union types.
//
// Protocol:
//   First line: "ok"
//   Remainder: the Markdown text (may contain newlines freely).
package Lyric.DocBridge

import Lyric.Doc

pub func generateToProtocol(source: in String): String {
  "ok\n" + generate(source)
}
