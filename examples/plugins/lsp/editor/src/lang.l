//! Editor.Lang — the plugin API an editor offers to language servers
//! (docs/69 §4.3). `LanguageServer` is a protocol point: its messages are
//! LSP 3.17's, not Lyric methods, so a server written in any language plugs
//! in. The editor routes the server's `workspace/applyEdit` requests through
//! the `WorkspaceEdit` capability, so a server can change only the documents
//! its grant names.
package Editor.Lang

import Std.Core
import Std.Collections
import Std.Plugin

/// One LSP `TextEdit`: replace the text between two positions (zero-based
/// line and UTF-16 character offsets, end exclusive) with `newText`.
pub exposed record TextEdit {
  startLine: Int
  startCharacter: Int
  endLine: Int
  endCharacter: Int
  newText: String
}

/// The edits to one document.
pub exposed record DocumentEdit {
  uri: String
  edits: List[TextEdit]
}

/// The documents a server may edit: those whose URI starts with one of
/// `roots`.
pub exposed record WorkspaceEditGrant {
  roots: List[String]
}

pub func uriWithin(uri: in String, roots: in List[String]): Bool {
  for r in roots {
    if uri.startsWith(r) {
      return true
    }
  }
  false
}

@capability(grant = WorkspaceEditGrant)
pub interface WorkspaceEdit {
  /// Apply `edit`; `Ok(false)` when the editor declined it.
  func applyEdit(edit: in DocumentEdit): Result[Bool, String]
    requires: uriWithin(edit.uri, grant.roots)
}

/// What a language server handles, read from its manifest without starting
/// it.
pub exposed record LanguageContributions {
  languageIds: List[String]
  fileGlobs: List[String]
}

@protocol_point(protocol = "lsp/3.17", version = "1.0", contributions = LanguageContributions, allows(WorkspaceEdit))
pub interface LanguageServer {
}
