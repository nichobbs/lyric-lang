// stdlib/tests/xml_viability_tests.l — Viability probe for a pure-Lyric XML parser.
//
// Tests three things that could block Option B (a hand-rolled parser):
//
//   1. Self-referential union: `XmlNode` holds `List[XmlNode]` children.
//   2. Recursive traversal: functions that structurally walk the tree.
//   3. Character-level string parsing: the primitives a real XML parser uses.
//
// A clean exit (code 0 + "ok" in stdout) confirms the emitter handles all three.

package Xml.Viability.Tests

import Std.Core
import Std.Collections
import Std.String
import Std.Char
import Std.Testing

// ---------------------------------------------------------------------------
// 1. Data model — the self-referential union type under test.
// ---------------------------------------------------------------------------

union XmlNode {
  case Element(tag: String, children: List[XmlNode])
  case Text(value: String)
}

// ---------------------------------------------------------------------------
// 2. Recursive traversal functions.
// ---------------------------------------------------------------------------

func countNodes(node: in XmlNode): Int {
  match node {
    case Text(v) -> 1
    case Element(tag, children) -> {
      var n = 1
      var i = 0
      while i < children.count {
        n += countNodes(children[i])
        i += 1
      }
      n
    }
  }
}

func textContent(node: in XmlNode): String {
  match node {
    case Text(v) -> v
    case Element(tag, children) -> {
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

func treeDepth(node: in XmlNode): Int {
  match node {
    case Text(v) -> 1
    case Element(tag, children) -> {
      if children.count == 0 { return 1 }
      var maxChild = 0
      var i = 0
      while i < children.count {
        val d = treeDepth(children[i])
        if d > maxChild { maxChild = d }
        i += 1
      }
      1 + maxChild
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Mini tokenizer — the exact string-walking pattern a parser would use.
//
// Token kinds: 1=open-angle, 2=close-angle, 3=slash, 4=equals,
//              5=whitespace, 6=name-char
// ---------------------------------------------------------------------------

func tokenize(src: in String): List[Int] {
  val tokens: List[Int] = newList()
  var i = 0
  while i < src.length {
    val c = src[i]
    val kind =
      if c == '<' {
        1
      } else if c == '>' {
        2
      } else if c == '/' {
        3
      } else if c == '=' {
        4
      } else if isWhiteSpace(c) {
        5
      } else {
        6
      }
    tokens.add(kind)
    i += 1
  }
  tokens
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

func testSelfReferentialUnion(): Unit {
  // Build: <root><child>hello</child><child>world</child></root>
  val inner1: List[XmlNode] = newList()
  inner1.add(Text(value = "hello"))

  val inner2: List[XmlNode] = newList()
  inner2.add(Text(value = "world"))

  val child1 = Element(tag = "child", children = inner1)
  val child2 = Element(tag = "child", children = inner2)

  val rootChildren: List[XmlNode] = newList()
  rootChildren.add(child1)
  rootChildren.add(child2)
  val root = Element(tag = "root", children = rootChildren)

  // 1 root + 2 element children + 2 text leaves
  assertEqualInt(countNodes(root), 5, "countNodes")
  assertTrue(textContent(root) == "helloworld", "textContent")
  assertEqualInt(treeDepth(root), 3, "treeDepth: root -> child -> text = 3")
}

func testEmptyElement(): Unit {
  val children: List[XmlNode] = newList()
  val empty = Element(tag = "br", children = children)
  assertEqualInt(countNodes(empty), 1, "empty element: 1 node")
  assertTrue(textContent(empty) == "", "empty element: no text")
  assertEqualInt(treeDepth(empty), 1, "empty element: depth 1")
}

func testTextNode(): Unit {
  val t = Text(value = "hello")
  assertEqualInt(countNodes(t), 1, "text node: 1 node")
  assertTrue(textContent(t) == "hello", "text node: content")
  assertEqualInt(treeDepth(t), 1, "text node: depth 1")
}

func testDeepNesting(): Unit {
  // Build a linearly-nested chain 5 levels deep.
  val leaf: List[XmlNode] = newList()
  leaf.add(Text(value = "x"))
  var current: List[XmlNode] = newList()
  current.add(Element(tag = "d", children = leaf))
  var level = 0
  while level < 3 {
    val next: List[XmlNode] = newList()
    next.add(Element(tag = "d", children = current))
    current = next
    level += 1
  }
  val root = Element(tag = "root", children = current)
  assertEqualInt(treeDepth(root), 6, "deep nesting: depth 6")
  assertTrue(textContent(root) == "x", "deep nesting: text content survives")
}

func testTokenizer(): Unit {
  // "<foo>hello</foo>" → 16 characters
  // < f  o  o  >  h  e  l  l  o  <  /  f  o  o  >
  // 1 6  6  6  2  6  6  6  6  6  1  3  6  6  6  2
  val tokens = tokenize("<foo>hello</foo>")
  assertEqualInt(tokens.count, 16, "token count")
  assertEqualInt(tokens[0], 1, "tokens[0] = '<'")
  assertEqualInt(tokens[4], 2, "tokens[4] = '>'")
  assertEqualInt(tokens[10], 1, "tokens[10] = '<' (closing tag)")
  assertEqualInt(tokens[11], 3, "tokens[11] = '/'")
  assertEqualInt(tokens[15], 2, "tokens[15] = '>' (end)")
}

func testTokenizerWithWhitespace(): Unit {
  val tokens = tokenize("< a = b >")
  // < sp a sp = sp b sp >
  // 1  5  6  5  4  5  6  5  2
  assertEqualInt(tokens.count, 9, "token count with whitespace")
  assertEqualInt(tokens[0], 1, "open angle")
  assertEqualInt(tokens[1], 5, "space")
  assertEqualInt(tokens[4], 4, "equals")
  assertEqualInt(tokens[8], 2, "close angle")
}

func main(): Unit {
  testSelfReferentialUnion()
  testEmptyElement()
  testTextNode()
  testDeepNesting()
  testTokenizer()
  testTokenizerWithWhitespace()
  println("xml_viability: ok")
}
