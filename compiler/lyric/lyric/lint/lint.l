// lint/lint.l — self-hosted `lyric lint` style and quality checker.
// Mirrors compiler/src/Lyric.Cli/Lint.fs (Phase 5 §M5.3 shim elimination).
// Five AST-only rules: L001-L005.
package Lyric.Lint

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─── Diagnostic types ─────────────────────────────────────────────────────────

pub union LintSev {
  case LintError
  case LintWarning
}

pub record LintDiag {
  code:     String
  severity: LintSev
  message:  String
  span:     Span
}

// ─── Character helpers (ASCII only — naming rules are ASCII) ──────────────────

func isAsciiUpper(c: in Char): Bool { c >= 'A' and c <= 'Z' }
func isAsciiLower(c: in Char): Bool { c >= 'a' and c <= 'z' }
func isAsciiDigit(c: in Char): Bool { c >= '0' and c <= '9' }

func startsUpper(s: in String): Bool {
  s.length > 0 and isAsciiUpper(s[0])
}

func startsLower(s: in String): Bool {
  s.length > 0 and isAsciiLower(s[0])
}

func isUpperSnake(s: in String): Bool {
  if s.length == 0 { return false }
  var i = 0
  var ok = true
  while i < s.length and ok {
    val c = s[i]
    if not (isAsciiUpper(c) or isAsciiDigit(c) or c == '_') {
      ok = false
    }
    i = i + 1
  }
  ok
}

// ─── Rule helpers ─────────────────────────────────────────────────────────────

func lintError(code: in String, msg: in String, sp: in Span): LintDiag {
  LintDiag(code = code, severity = LintError, message = msg, span = sp)
}

func lintWarning(code: in String, msg: in String, sp: in Span): LintDiag {
  LintDiag(code = code, severity = LintWarning, message = msg, span = sp)
}

// L001 — type name must start with an uppercase letter.
func checkTypeName(name: in String, sp: in Span): List[LintDiag] {
  if startsUpper(name) { return newList() }
  val acc: List[LintDiag] = newList()
  acc.add(lintError("L001",
    "type name '" + name + "' should be PascalCase (start with an uppercase letter)", sp))
  acc
}

// L002 — function name must start with a lowercase letter.
func checkFuncName(name: in String, sp: in Span): List[LintDiag] {
  if startsLower(name) { return newList() }
  val acc: List[LintDiag] = newList()
  acc.add(lintError("L002",
    "function name '" + name + "' should be camelCase (start with a lowercase letter)", sp))
  acc
}

// L003 — pub item should have a doc comment.
func checkPubDoc(vis: in Option[Visibility], docs: in List[DocComment],
                 name: in String, kind: in String, sp: in Span): List[LintDiag] {
  match vis {
    case None    -> newList()
    case Some(_) -> {
      if docs.count > 0 { return newList() }
      val acc: List[LintDiag] = newList()
      acc.add(lintWarning("L003",
        "pub " + kind + " '" + name + "' has no doc comment (///)", sp))
      acc
    }
  }
}

// L004 — doc comment contains TODO or FIXME.
func checkDocTodos(docs: in List[DocComment]): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  var i = 0
  while i < docs.count {
    val d = docs[i]
    val docText = d.text
    var found = false
    var j = 0
    while j + 3 < docText.length and not found {
      if (docText[j] == 'T' or docText[j] == 't') and
         (docText[j+1] == 'O' or docText[j+1] == 'o') and
         (docText[j+2] == 'D' or docText[j+2] == 'd') and
         (docText[j+3] == 'O' or docText[j+3] == 'o') {
        found = true
      }
      j = j + 1
    }
    var j2 = 0
    while j2 + 4 < docText.length and not found {
      if (docText[j2] == 'F' or docText[j2] == 'f') and
         (docText[j2+1] == 'I' or docText[j2+1] == 'i') and
         (docText[j2+2] == 'X' or docText[j2+2] == 'x') and
         (docText[j2+3] == 'M' or docText[j2+3] == 'm') and
         (docText[j2+4] == 'E' or docText[j2+4] == 'e') {
        found = true
      }
      j2 = j2 + 1
    }
    if found {
      acc.add(lintWarning("L004",
        "doc comment contains TODO/FIXME: '" + docText + "'", d.span))
    }
    i = i + 1
  }
  acc
}

// L005 — pub func with a block body should declare at least one contract.
func checkPubContract(vis: in Option[Visibility], fn: in FunctionDecl): List[LintDiag] {
  match vis {
    case None    -> newList()
    case Some(_) -> {
      match fn.body {
        case Some(body) -> {
          match body {
            case FBBlock(_) -> {
              if fn.contracts.count == 0 {
                val acc: List[LintDiag] = newList()
                acc.add(lintWarning("L005",
                  "pub func '" + fn.name + "' has no requires/ensures contracts — consider adding contracts or marking the module @runtime_checked",
                  fn.span))
                acc
              } else {
                newList()
              }
            }
            case _ -> newList()
          }
        }
        case None -> newList()
      }
    }
  }
}

// ─── List concat helper ───────────────────────────────────────────────────────

func appendDiags(target: in List[LintDiag], src: in List[LintDiag]) {
  var i = 0
  while i < src.count {
    target.add(src[i])
    i = i + 1
  }
}

// ─── Item walker ──────────────────────────────────────────────────────────────

func checkItem(item: in Item): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val vis  = item.visibility
  val docs = item.docComments
  match item.kind {
    case IFunc(fn) -> {
      appendDiags(acc, checkFuncName(fn.name, fn.span))
      appendDiags(acc, checkPubDoc(vis, docs, fn.name, "func", item.span))
      appendDiags(acc, checkDocTodos(docs))
      appendDiags(acc, checkPubContract(vis, fn))
    }
    case IRecord(rd) -> {
      appendDiags(acc, checkTypeName(rd.name, rd.span))
      appendDiags(acc, checkPubDoc(vis, docs, rd.name, "record", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IExposedRec(rd) -> {
      appendDiags(acc, checkTypeName(rd.name, rd.span))
      appendDiags(acc, checkPubDoc(vis, docs, rd.name, "exposed record", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IUnion(ud) -> {
      appendDiags(acc, checkTypeName(ud.name, ud.span))
      appendDiags(acc, checkPubDoc(vis, docs, ud.name, "union", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IEnum(ed) -> {
      appendDiags(acc, checkTypeName(ed.name, ed.span))
      appendDiags(acc, checkPubDoc(vis, docs, ed.name, "enum", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IOpaque(od) -> {
      appendDiags(acc, checkTypeName(od.name, od.span))
      appendDiags(acc, checkPubDoc(vis, docs, od.name, "opaque type", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IProtected(pd) -> {
      appendDiags(acc, checkTypeName(pd.name, pd.span))
      appendDiags(acc, checkPubDoc(vis, docs, pd.name, "protected type", item.span))
      appendDiags(acc, checkDocTodos(docs))
      var mi = 0
      while mi < pd.members.count {
        match pd.members[mi] {
          case PMEntry(ed) -> {
            appendDiags(acc, checkFuncName(ed.name, ed.span))
            appendDiags(acc, checkPubDoc(ed.visibility, ed.docComments, ed.name, "entry", ed.span))
            appendDiags(acc, checkDocTodos(ed.docComments))
          }
          case PMFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
          }
          case _ -> ()
        }
        mi = mi + 1
      }
    }
    case IInterface(id) -> {
      appendDiags(acc, checkTypeName(id.name, id.span))
      appendDiags(acc, checkPubDoc(vis, docs, id.name, "interface", item.span))
      appendDiags(acc, checkDocTodos(docs))
      var mi = 0
      while mi < id.members.count {
        match id.members[mi] {
          case IMSig(sg) -> {
            appendDiags(acc, checkFuncName(sg.name, sg.span))
          }
          case IMFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
          }
          case IMAssoc(_) -> ()
        }
        mi = mi + 1
      }
    }
    case IImpl(id) -> {
      appendDiags(acc, checkDocTodos(docs))
      var mi = 0
      while mi < id.members.count {
        match id.members[mi] {
          case IMplFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
          }
          case IMplAssoc(_) -> ()
        }
        mi = mi + 1
      }
    }
    case IDistinctType(dt) -> {
      appendDiags(acc, checkTypeName(dt.name, dt.span))
      appendDiags(acc, checkPubDoc(vis, docs, dt.name, "distinct type", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case ITypeAlias(ta) -> {
      appendDiags(acc, checkTypeName(ta.name, ta.span))
      appendDiags(acc, checkPubDoc(vis, docs, ta.name, "type alias", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IConst(cd) -> {
      val nameOk = startsUpper(cd.name) or isUpperSnake(cd.name)
      if not nameOk {
        acc.add(lintWarning("L001",
          "const '" + cd.name + "' should be PascalCase or UPPER_SNAKE_CASE", cd.span))
      }
      appendDiags(acc, checkPubDoc(vis, docs, cd.name, "const", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case _ -> {
      appendDiags(acc, checkDocTodos(docs))
    }
  }
  acc
}

// ─── Sort helper (insertion sort by line/col) ─────────────────────────────────

func sortDiags(diags: in List[LintDiag]): List[LintDiag] {
  val n = diags.count
  var i = 1
  while i < n {
    val key = diags[i]
    var j = i - 1
    while j >= 0 {
      val dj = diags[j]
      val kLine  = key.span.startPos.line
      val djLine = dj.span.startPos.line
      val kCol   = key.span.startPos.column
      val djCol  = dj.span.startPos.column
      if djLine > kLine or (djLine == kLine and djCol > kCol) {
        diags[j + 1] = dj
        j = j - 1
      } else {
        break
      }
    }
    diags[j + 1] = key
    i = i + 1
  }
  diags
}

// ─── Public entry ─────────────────────────────────────────────────────────────

pub func lint(source: in String): List[LintDiag] {
  val pr   = parse(source)
  val file = pr.file
  val acc: List[LintDiag] = newList()
  var i = 0
  while i < file.items.count {
    appendDiags(acc, checkItem(file.items[i]))
    i = i + 1
  }
  sortDiags(acc)
}
