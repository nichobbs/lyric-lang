// std/xml.l — Pure-Lyric XML 1.0 parser.
//
// Parses a string containing XML and returns a document tree.
// No namespace support; namespace-qualified names (e.g. "ns:elem")
// are treated as plain names.  Entity references (&amp; &lt; &gt;
// &apos; &quot; &#NNN; &#xNNN;) are decoded in text and attribute
// values.  DOCTYPE and processing-instruction nodes are consumed but
// not represented in the tree.  CDATA sections and comments are
// preserved in the tree as CData/Comment nodes.
//
// Cross-platform: no BCL/JVM externs. Works on both MSIL and JVM
// targets without any kernel bridge.
@runtime_checked
package Std.Xml

import Std.Core
import Std.Collections
import Std.String
import Std.Char

// ── Error type ─────────────────────────────────────────────────────────────────

pub union XmlError {
  case UnexpectedChar(pos: Int, expected: String)
  case UnexpectedEof(pos: Int, expected: String)
  case MismatchedTag(pos: Int, opened: String, closed: String)
  case InvalidDocument(message: String)
}

pub func XmlError.message(e: in XmlError): String {
  match e {
    case UnexpectedChar(pos, expected) ->
      "unexpected character at position " + toString(pos) + "; expected " + expected
    case UnexpectedEof(pos, expected) ->
      "unexpected end of input at position " + toString(pos) + "; expected " + expected
    case MismatchedTag(pos, opened, closed) ->
      "mismatched tags at position " + toString(pos) +
      ": opened <" + opened + ">, closed </" + closed + ">"
    case InvalidDocument(msg) ->
      "invalid XML document: " + msg
  }
}

// ── Data model ─────────────────────────────────────────────────────────────────

pub record XmlAttr {
  name:  String
  value: String
}

pub union XmlNode {
  case Element(tag: String, attrs: List[XmlAttr], children: List[XmlNode])
  case Text(value: String)
  case Comment(value: String)
  case CData(value: String)
}

pub record XmlDoc {
  version:  Option[String]
  encoding: Option[String]
  root:     XmlNode
}

// ── Parser state ───────────────────────────────────────────────────────────────

record XmlState {
  src: String
  pos: Int
}

// ── Low-level character utilities ──────────────────────────────────────────────

func xAtEnd(st: in XmlState): Bool {
  st.pos >= st.src.length
}

func xPeek(st: in XmlState): Option[Char] {
  if st.pos < st.src.length {
    Some(value = st.src[st.pos])
  } else {
    None
  }
}

func xPeekAt(st: in XmlState, offset: in Int): Option[Char] {
  val i = st.pos + offset
  if i >= 0 and i < st.src.length {
    Some(value = st.src[i])
  } else {
    None
  }
}

func xSkipWs(st: inout XmlState): Unit {
  while st.pos < st.src.length and isWhiteSpace(st.src[st.pos]) {
    st.pos = st.pos + 1
  }
}

func xEat(st: inout XmlState, c: in Char): Bool {
  if st.pos < st.src.length and st.src[st.pos] == c {
    st.pos = st.pos + 1
    true
  } else {
    false
  }
}

func xStartsWith(st: in XmlState, s: in String): Bool {
  val remaining = st.src.length - st.pos
  if remaining < s.length {
    false
  } else {
    st.src.substring(st.pos, s.length) == s
  }
}

func xEatStr(st: inout XmlState, s: in String): Bool {
  if xStartsWith(st, s) {
    st.pos = st.pos + s.length
    true
  } else {
    false
  }
}

// ── Name parsing ───────────────────────────────────────────────────────────────

func xIsNameStart(c: in Char): Bool {
  isLetter(c) or c == '_' or c == ':'
}

func xIsNameContinue(c: in Char): Bool {
  isLetterOrDigit(c) or c == '_' or c == ':' or c == '-' or c == '.'
}

func xParseName(st: inout XmlState): Option[String] {
  if xAtEnd(st) { return None }
  val c = st.src[st.pos]
  if not xIsNameStart(c) { return None }
  val start = st.pos
  st.pos = st.pos + 1
  while st.pos < st.src.length and xIsNameContinue(st.src[st.pos]) {
    st.pos = st.pos + 1
  }
  Some(value = st.src.substring(start, st.pos - start))
}

// ── Entity decoding ────────────────────────────────────────────────────────────

func xDecodeNamedEntity(name: in String): Option[Char] {
  if name == "amp" {
    Some(value = '&')
  } else if name == "lt" {
    Some(value = '<')
  } else if name == "gt" {
    Some(value = '>')
  } else if name == "apos" {
    Some(value = '\'')
  } else if name == "quot" {
    Some(value = '"')
  } else {
    None
  }
}

func xParseHexDigit(c: in Char): Int {
  if c >= '0' and c <= '9' {
    toInt(c) - toInt('0')
  } else if c >= 'a' and c <= 'f' {
    10 + toInt(c) - toInt('a')
  } else if c >= 'A' and c <= 'F' {
    10 + toInt(c) - toInt('A')
  } else {
    -1
  }
}

// Parse an entity reference starting just after '&'.
// Consumes through the closing ';'.
func xParseEntity(st: inout XmlState): Result[String, XmlError] {
  val startPos = st.pos
  if xAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "entity reference"))
  }
  if st.src[st.pos] == '#' {
    st.pos = st.pos + 1
    if xAtEnd(st) {
      return Err(error = UnexpectedEof(pos = st.pos, expected = "numeric entity"))
    }
    if st.src[st.pos] == 'x' or st.src[st.pos] == 'X' {
      // Hex: &#xNNN; or &#XNNN;
      st.pos = st.pos + 1
      var value = 0
      var digits = 0
      var scanning = true
      while scanning and st.pos < st.src.length {
        val d = xParseHexDigit(st.src[st.pos])
        if d >= 0 {
          value = value * 16 + d
          st.pos = st.pos + 1
          digits += 1
        } else {
          scanning = false
        }
      }
      if digits == 0 {
        return Err(error = UnexpectedChar(pos = st.pos, expected = "hex digit in entity"))
      }
      if not xEat(st, ';') {
        return Err(error = UnexpectedChar(pos = st.pos, expected = "';' to close entity"))
      }
      Ok(value = "" + fromInt(value))
    } else {
      // Decimal: &#NNN;
      var value = 0
      var digits = 0
      var scanning = true
      while scanning and st.pos < st.src.length {
        val c = st.src[st.pos]
        if c >= '0' and c <= '9' {
          value = value * 10 + toInt(c) - toInt('0')
          st.pos = st.pos + 1
          digits += 1
        } else {
          scanning = false
        }
      }
      if digits == 0 {
        return Err(error = UnexpectedChar(pos = st.pos, expected = "decimal digit in entity"))
      }
      if not xEat(st, ';') {
        return Err(error = UnexpectedChar(pos = st.pos, expected = "';' to close entity"))
      }
      Ok(value = "" + fromInt(value))
    }
  } else {
    // Named entity: &name;
    match xParseName(st) {
      case None -> Err(error = UnexpectedChar(pos = startPos, expected = "entity name"))
      case Some(name) -> {
        if not xEat(st, ';') {
          return Err(error = UnexpectedChar(pos = st.pos, expected = "';' to close entity"))
        }
        match xDecodeNamedEntity(name) {
          case None -> Err(error = UnexpectedChar(pos = startPos, expected = "known entity name"))
          case Some(c) -> Ok(value = "" + c)
        }
      }
    }
  }
}

// Collect text until stopChar or '<', decoding entity references.
func xCollectText(st: inout XmlState, stopChar: in Option[Char]): Result[String, XmlError] {
  var result = ""
  var scanning = true
  while scanning and st.pos < st.src.length {
    val c = st.src[st.pos]
    val isStop =
      if c == '<' {
        true
      } else {
        match stopChar {
          case Some(sc) -> c == sc
          case None     -> false
        }
      }
    if isStop {
      scanning = false
    } else if c == '&' {
      st.pos = st.pos + 1
      match xParseEntity(st) {
        case Err(e) -> {
          scanning = false
          result = result + "?"
        }
        case Ok(s)  -> { result = result + s }
      }
    } else {
      result = result + "" + c
      st.pos = st.pos + 1
    }
  }
  Ok(value = result)
}

// ── Attribute value parsing ─────────────────────────────────────────────────────

func xParseAttrValue(st: inout XmlState): Result[String, XmlError] {
  if xAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "attribute value"))
  }
  val quote = st.src[st.pos]
  if quote != '"' and quote != '\'' {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "quote to start attribute value"))
  }
  st.pos = st.pos + 1
  match xCollectText(st, Some(value = quote)) {
    case Err(e) -> Err(error = e)
    case Ok(v)  -> {
      if not xEat(st, quote) {
        Err(error = UnexpectedEof(pos = st.pos, expected = "closing quote"))
      } else {
        Ok(value = v)
      }
    }
  }
}

// ── Attribute list parsing ──────────────────────────────────────────────────────

func xParseAttrs(st: inout XmlState): Result[List[XmlAttr], XmlError] {
  val attrs: List[XmlAttr] = newList()
  var ok = true
  var err: XmlError = InvalidDocument(message = "")
  xSkipWs(st)
  while ok and st.pos < st.src.length and st.src[st.pos] != '>' and not xStartsWith(st, "/>") {
    match xParseName(st) {
      case None -> {
        ok = false
        err = UnexpectedChar(pos = st.pos, expected = "attribute name")
      }
      case Some(name) -> {
        xSkipWs(st)
        if not xEat(st, '=') {
          ok = false
          err = UnexpectedChar(pos = st.pos, expected = "'=' after attribute name")
        } else {
          xSkipWs(st)
          match xParseAttrValue(st) {
            case Err(e) -> {
              ok = false
              err = e
            }
            case Ok(v) -> {
              attrs.add(XmlAttr(name = name, value = v))
              xSkipWs(st)
            }
          }
        }
      }
    }
  }
  if ok { Ok(value = attrs) } else { Err(error = err) }
}

// ── Comment parsing: <!-- … --> ────────────────────────────────────────────────

func xParseComment(st: inout XmlState): Result[XmlNode, XmlError] {
  // Caller has already consumed "<!--"
  val start = st.pos
  var found = false
  while not found and not xAtEnd(st) {
    if xStartsWith(st, "-->") {
      found = true
    } else {
      st.pos = st.pos + 1
    }
  }
  if not found {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "'-->' to close comment"))
  }
  val content = st.src.substring(start, st.pos - start)
  st.pos = st.pos + 3  // consume "-->"
  Ok(value = Comment(value = content))
}

// ── CDATA parsing: <![CDATA[ … ]]> ────────────────────────────────────────────

func xParseCData(st: inout XmlState): Result[XmlNode, XmlError] {
  // Caller has consumed "<![CDATA["
  val start = st.pos
  var found = false
  while not found and not xAtEnd(st) {
    if xStartsWith(st, "]]>") {
      found = true
    } else {
      st.pos = st.pos + 1
    }
  }
  if not found {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "']]>' to close CDATA"))
  }
  val content = st.src.substring(start, st.pos - start)
  st.pos = st.pos + 3  // consume "]]>"
  Ok(value = CData(value = content))
}

// ── Processing instruction / DOCTYPE: skip ──────────────────────────────────────

func xSkipToGt(st: inout XmlState): Result[Unit, XmlError] {
  var depth = 0
  var found = false
  while not found and not xAtEnd(st) {
    val c = st.src[st.pos]
    if c == '<' {
      depth += 1
      st.pos = st.pos + 1
    } else if c == '>' {
      if depth == 0 {
        found = true
        st.pos = st.pos + 1
      } else {
        depth -= 1
        st.pos = st.pos + 1
      }
    } else {
      st.pos = st.pos + 1
    }
  }
  if found { Ok(value = ()) } else { Err(error = UnexpectedEof(pos = st.pos, expected = "'>'")) }
}

func xSkipPI(st: inout XmlState): Result[Unit, XmlError] {
  // Caller consumed "<?"; skip until "?>"
  var found = false
  while not found and not xAtEnd(st) {
    if xStartsWith(st, "?>") {
      found = true
      st.pos = st.pos + 2
    } else {
      st.pos = st.pos + 1
    }
  }
  if found { Ok(value = ()) } else { Err(error = UnexpectedEof(pos = st.pos, expected = "'?>'")) }
}

// ── XML declaration: <?xml version="…" encoding="…"?> ─────────────────────────

// Returns (version, encoding). Caller has consumed "<?xml".
func xParseXmlDecl(st: inout XmlState): Result[Unit, XmlError] {
  xSkipWs(st)
  // Collect pseudo-attributes until "?>"
  var ok = true
  var err: XmlError = InvalidDocument(message = "")
  while ok and not xStartsWith(st, "?>") and not xAtEnd(st) {
    match xParseName(st) {
      case None -> {
        ok = false
        err = UnexpectedChar(pos = st.pos, expected = "attribute name in XML declaration")
      }
      case Some(_) -> {
        xSkipWs(st)
        if xEat(st, '=') {
          xSkipWs(st)
          match xParseAttrValue(st) {
            case Err(e) -> { ok = false; err = e }
            case Ok(_)  -> xSkipWs(st)
          }
        }
      }
    }
  }
  if not ok { return Err(error = err) }
  if not xEatStr(st, "?>") {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "'?>' to close XML declaration"))
  }
  Ok(value = ())
}

// ── Element parsing (forward-declared via mutual recursion workaround) ──────────

// Parse element content: text nodes, child elements, comments, CDATA.
// Stops when it sees the closing tag </expectedTag> and consumes it.
func xParseContent(st: inout XmlState, expectedTag: in String): Result[List[XmlNode], XmlError] {
  val children: List[XmlNode] = newList()
  var ok = true
  var err: XmlError = InvalidDocument(message = "")
  var done = false
  while ok and not done and not xAtEnd(st) {
    if st.src[st.pos] == '<' {
      if xStartsWith(st, "</") {
        // Closing tag — verify it matches and consume it.
        done = true
        st.pos = st.pos + 2
        xSkipWs(st)
        match xParseName(st) {
          case None -> {
            ok = false
            err = UnexpectedChar(pos = st.pos, expected = "closing tag name")
          }
          case Some(closingTag) -> {
            xSkipWs(st)
            if not xEat(st, '>') {
              ok = false
              err = UnexpectedChar(pos = st.pos, expected = "'>' to close tag")
            } else if closingTag != expectedTag {
              ok = false
              err = MismatchedTag(pos = st.pos, opened = expectedTag, closed = closingTag)
            }
          }
        }
      } else if xStartsWith(st, "<!--") {
        st.pos = st.pos + 4
        match xParseComment(st) {
          case Err(e) -> { ok = false; err = e }
          case Ok(n)  -> children.add(n)
        }
      } else if xStartsWith(st, "<![CDATA[") {
        st.pos = st.pos + 9
        match xParseCData(st) {
          case Err(e) -> { ok = false; err = e }
          case Ok(n)  -> children.add(n)
        }
      } else if xStartsWith(st, "<?") {
        st.pos = st.pos + 2
        match xSkipPI(st) {
          case Err(e) -> { ok = false; err = e }
          case Ok(_)  -> ()
        }
      } else if xStartsWith(st, "<!") {
        st.pos = st.pos + 1
        match xSkipToGt(st) {
          case Err(e) -> { ok = false; err = e }
          case Ok(_)  -> ()
        }
      } else {
        // Child element
        match xParseElement(st) {
          case Err(e) -> { ok = false; err = e }
          case Ok(n)  -> children.add(n)
        }
      }
    } else {
      // Text content
      match xCollectText(st, None) {
        case Err(e) -> { ok = false; err = e }
        case Ok(t)  -> {
          if t.length > 0 {
            children.add(Text(value = t))
          }
        }
      }
    }
  }
  if not done and ok {
    ok = false
    err = UnexpectedEof(pos = st.pos, expected = "</" + expectedTag + ">")
  }
  if ok { Ok(value = children) } else { Err(error = err) }
}

// Parse one element starting at '<'. Consumes through the matching closing tag.
func xParseElement(st: inout XmlState): Result[XmlNode, XmlError] {
  if not xEat(st, '<') {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "'<' to start element"))
  }
  match xParseName(st) {
    case None -> Err(error = UnexpectedChar(pos = st.pos, expected = "element tag name"))
    case Some(tag) -> {
      match xParseAttrs(st) {
        case Err(e) -> Err(error = e)
        case Ok(attrs) -> {
          if xEatStr(st, "/>") {
            // Self-closing
            val children: List[XmlNode] = newList()
            Ok(value = Element(tag = tag, attrs = attrs, children = children))
          } else if xEat(st, '>') {
            // Has children
            match xParseContent(st, tag) {
              case Err(e) -> Err(error = e)
              case Ok(children) -> Ok(value = Element(tag = tag, attrs = attrs, children = children))
            }
          } else {
            Err(error = UnexpectedChar(pos = st.pos, expected = "'>' or '/>' to close opening tag"))
          }
        }
      }
    }
  }
}

// ── Prolog: skip misc nodes before the root element ───────────────────────────

func xParseProlog(st: inout XmlState): Result[Unit, XmlError] {
  var ok = true
  var err: XmlError = InvalidDocument(message = "")
  var done = false
  while ok and not done and not xAtEnd(st) {
    xSkipWs(st)
    if xAtEnd(st) {
      done = true
    } else if xStartsWith(st, "<?xml") {
      st.pos = st.pos + 5
      match xParseXmlDecl(st) {
        case Err(e) -> { ok = false; err = e }
        case Ok(_)  -> ()
      }
    } else if xStartsWith(st, "<!--") {
      st.pos = st.pos + 4
      match xParseComment(st) {
        case Err(e) -> { ok = false; err = e }
        case Ok(_)  -> ()
      }
    } else if xStartsWith(st, "<?") {
      st.pos = st.pos + 2
      match xSkipPI(st) {
        case Err(e) -> { ok = false; err = e }
        case Ok(_)  -> ()
      }
    } else if xStartsWith(st, "<!") {
      st.pos = st.pos + 1
      match xSkipToGt(st) {
        case Err(e) -> { ok = false; err = e }
        case Ok(_)  -> ()
      }
    } else {
      done = true  // hit the root element
    }
  }
  if ok { Ok(value = ()) } else { Err(error = err) }
}

// ── Public API ─────────────────────────────────────────────────────────────────

/// Parse an XML string, returning the document tree or an error.
@stable(since="0.1")
pub func parseXml(src: in String): Result[XmlDoc, XmlError] {
  var st = XmlState(src = src, pos = 0)
  match xParseProlog(st) {
    case Err(e) -> Err(error = e)
    case Ok(_)  -> {
      xSkipWs(st)
      if xAtEnd(st) {
        return Err(error = InvalidDocument(message = "document is empty"))
      }
      match xParseElement(st) {
        case Err(e) -> Err(error = e)
        case Ok(root) -> Ok(value = XmlDoc(version = None, encoding = None, root = root))
      }
    }
  }
}

/// Return the root element of the document.
@stable(since="0.1")
pub func documentRoot(doc: in XmlDoc): XmlNode {
  doc.root
}

/// Return the tag name of an element node, or None if not an element.
@stable(since="0.1")
pub func elementTag(node: in XmlNode): Option[String] {
  match node {
    case Element(tag, attrs, children) -> Some(value = tag)
    case Text(_)    -> None
    case Comment(_) -> None
    case CData(_)   -> None
  }
}

/// Return the attribute list of an element, or an empty list.
@stable(since="0.1")
pub func elementAttrs(node: in XmlNode): List[XmlAttr] {
  match node {
    case Element(tag, attrs, children) -> attrs
    case _ -> {
      val empty: List[XmlAttr] = newList()
      empty
    }
  }
}

/// Return the child nodes of an element, or an empty list.
@stable(since="0.1")
pub func elementChildren(node: in XmlNode): List[XmlNode] {
  match node {
    case Element(tag, attrs, children) -> children
    case _ -> {
      val empty: List[XmlNode] = newList()
      empty
    }
  }
}

/// Return the value of a named attribute, or None if absent.
@stable(since="0.1")
pub func getAttribute(node: in XmlNode, name: in String): Option[String] {
  val attrs = elementAttrs(node)
  var i = 0
  var found: Option[String] = None
  while i < attrs.count and isNone(found) {
    if attrs[i].name == name {
      found = Some(value = attrs[i].value)
    }
    i += 1
  }
  found
}

/// Collect all text content within a node, depth-first.
@stable(since="0.1")
pub func textContent(node: in XmlNode): String {
  match node {
    case Text(v)    -> v
    case CData(v)   -> v
    case Comment(_) -> ""
    case Element(tag, attrs, children) -> {
      var result = ""
      var i = 0
      while i < children.count {
        result = result + textContent(children[i])
        i += 1
      }
      result
    }
  }
}

/// Find the first descendant element (depth-first) with the given tag.
@stable(since="0.1")
pub func findFirst(node: in XmlNode, tag: in String): Option[XmlNode] {
  match node {
    case Text(_)    -> None
    case Comment(_) -> None
    case CData(_)   -> None
    case Element(t, attrs, children) -> {
      if t == tag {
        Some(value = node)
      } else {
        var result: Option[XmlNode] = None
        var i = 0
        while i < children.count and isNone(result) {
          result = findFirst(children[i], tag)
          i += 1
        }
        result
      }
    }
  }
}

/// Collect all descendant elements (depth-first) with the given tag.
@stable(since="0.1")
pub func findAll(node: in XmlNode, tag: in String): List[XmlNode] {
  val result: List[XmlNode] = newList()
  xCollectAll(node, tag, result)
  result
}

func xCollectAll(node: in XmlNode, tag: in String, acc: in List[XmlNode]): Unit {
  match node {
    case Text(_)    -> ()
    case Comment(_) -> ()
    case CData(_)   -> ()
    case Element(t, attrs, children) -> {
      if t == tag { acc.add(node) }
      var i = 0
      while i < children.count {
        xCollectAll(children[i], tag, acc)
        i += 1
      }
    }
  }
}
