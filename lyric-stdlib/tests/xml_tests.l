//! stdlib/tests/xml_tests.l — Tests for Std.Xml.
//!
//! Covers: document parsing, self-closing elements, nested elements,
//! text content, attributes, entity references, CDATA, comments,
//! XML declaration, findFirst/findAll, and error cases.
package Std.Xml.Tests

import Std.Core
import Std.Collections
import Std.Xml
import Std.Testing

func testSelfClosing(): Unit {
  match parseXml("<br/>") {
    case Err(e) -> assertTrue(false, "self-closing: " + XmlError.message(e))
    case Ok(doc) -> {
      val root = documentRoot(doc)
      match elementTag(root) {
        case Some(t) -> assertTrue(t == "br", "self-closing tag")
        case None -> assertTrue(false, "self-closing: expected element")
      }
      assertEqualInt(elementChildren(root).count, 0, "self-closing has no children")
    }
  }
}

func testTextContent(): Unit {
  match parseXml("<msg>hello world</msg>") {
    case Err(e) -> assertTrue(false, "text: " + XmlError.message(e))
    case Ok(doc) -> {
      val root = documentRoot(doc)
      assertTrue(textContent(root) == "hello world", "text content")
    }
  }
}

func testAttributes(): Unit {
  match parseXml("<a x=\"1\" y=\"hello\" z='bye'/>") {
    case Err(e) -> assertTrue(false, "attrs: " + XmlError.message(e))
    case Ok(doc) -> {
      val root = documentRoot(doc)
      match getAttribute(root, "x") {
        case Some(v) -> assertTrue(v == "1", "attr x")
        case None -> assertTrue(false, "attr x missing")
      }
      match getAttribute(root, "y") {
        case Some(v) -> assertTrue(v == "hello", "attr y")
        case None -> assertTrue(false, "attr y missing")
      }
      match getAttribute(root, "z") {
        case Some(v) -> assertTrue(v == "bye", "attr z single-quote")
        case None -> assertTrue(false, "attr z missing")
      }
      assertTrue(isNone(getAttribute(root, "missing")), "missing attr is None")
    }
  }
}

func testNestedElements(): Unit {
  match parseXml("<root><a>1</a><b>2</b><c/></root>") {
    case Err(e) -> assertTrue(false, "nested: " + XmlError.message(e))
    case Ok(doc) -> {
      val root = documentRoot(doc)
      val kids = elementChildren(root)
      assertEqualInt(kids.count, 3, "nested child count")
      assertTrue(textContent(kids[0]) == "1", "child a")
      assertTrue(textContent(kids[1]) == "2", "child b")
      assertEqualInt(elementChildren(kids[2]).count, 0, "child c empty")
    }
  }
}

func testDeepNesting(): Unit {
  match parseXml("<a><b><c><d>leaf</d></c></b></a>") {
    case Err(e) -> assertTrue(false, "deep: " + XmlError.message(e))
    case Ok(doc) -> assertTrue(textContent(documentRoot(doc)) == "leaf", "deep text")
  }
}

func testEntityRefs(): Unit {
  match parseXml("<e>&amp;&lt;&gt;&apos;&quot;</e>") {
    case Err(e) -> assertTrue(false, "entity: " + XmlError.message(e))
    case Ok(doc) -> assertTrue(textContent(documentRoot(doc)) == "&<>'\"", "entity refs")
  }
}

func testNumericEntities(): Unit {
  match parseXml("<e>&#65;&#x42;</e>") {
    case Err(e) -> assertTrue(false, "numeric entity: " + XmlError.message(e))
    case Ok(doc) -> assertTrue(textContent(documentRoot(doc)) == "AB", "numeric entities")
  }
}

func testEntityInAttr(): Unit {
  match parseXml("<e val=\"a&amp;b\"/>") {
    case Err(e) -> assertTrue(false, "entity in attr: " + XmlError.message(e))
    case Ok(doc) -> {
      match getAttribute(documentRoot(doc), "val") {
        case Some(v) -> assertTrue(v == "a&b", "entity in attribute value")
        case None -> assertTrue(false, "val attr missing")
      }
    }
  }
}

func testComment(): Unit {
  match parseXml("<r><!-- a comment --><a/></r>") {
    case Err(e) -> assertTrue(false, "comment: " + XmlError.message(e))
    case Ok(doc) -> {
      val kids = elementChildren(documentRoot(doc))
      assertEqualInt(kids.count, 2, "comment + element = 2 children")
    }
  }
}

func testCData(): Unit {
  match parseXml("<r><![CDATA[<not-a-tag> & not-entity]]></r>") {
    case Err(e) -> assertTrue(false, "cdata: " + XmlError.message(e))
    case Ok(doc) -> {
      val t = textContent(documentRoot(doc))
      assertTrue(t == "<not-a-tag> & not-entity", "cdata content preserved")
    }
  }
}

func testXmlDeclaration(): Unit {
  match parseXml("<?xml version=\"1.0\" encoding=\"UTF-8\"?><root/>") {
    case Err(e) -> assertTrue(false, "xml decl: " + XmlError.message(e))
    case Ok(doc) -> {
      match elementTag(documentRoot(doc)) {
        case Some(t) -> assertTrue(t == "root", "root after xml decl")
        case None -> assertTrue(false, "xml decl: expected element")
      }
    }
  }
}

func testDocType(): Unit {
  match parseXml("<!DOCTYPE html><html><body/></html>") {
    case Err(e) -> assertTrue(false, "doctype: " + XmlError.message(e))
    case Ok(doc) -> {
      match elementTag(documentRoot(doc)) {
        case Some(t) -> assertTrue(t == "html", "root after DOCTYPE")
        case None -> assertTrue(false, "doctype: expected element")
      }
    }
  }
}

func testFindFirst(): Unit {
  match parseXml("<root><a><b id=\"1\"/></a><b id=\"2\"/></root>") {
    case Err(e) -> assertTrue(false, "findFirst: " + XmlError.message(e))
    case Ok(doc) -> {
      match findFirst(documentRoot(doc), "b") {
        case None -> assertTrue(false, "findFirst b: not found")
        case Some(n) -> {
          match getAttribute(n, "id") {
            case Some(v) -> assertTrue(v == "1", "findFirst returns first depth-first match")
            case None -> assertTrue(false, "findFirst: id attr missing")
          }
        }
      }
      assertTrue(isNone(findFirst(documentRoot(doc), "z")), "findFirst missing tag")
    }
  }
}

func testFindAll(): Unit {
  match parseXml("<root><item>a</item><item>b</item><sub><item>c</item></sub></root>") {
    case Err(e) -> assertTrue(false, "findAll: " + XmlError.message(e))
    case Ok(doc) -> {
      val items = findAll(documentRoot(doc), "item")
      assertEqualInt(items.count, 3, "findAll count")
      assertTrue(textContent(items[0]) == "a", "findAll[0]")
      assertTrue(textContent(items[1]) == "b", "findAll[1]")
      assertTrue(textContent(items[2]) == "c", "findAll[2]")
    }
  }
}

func testMixedContent(): Unit {
  match parseXml("<p>Hello <b>world</b>!</p>") {
    case Err(e) -> assertTrue(false, "mixed: " + XmlError.message(e))
    case Ok(doc) -> {
      assertTrue(textContent(documentRoot(doc)) == "Hello world!", "mixed content text")
      val kids = elementChildren(documentRoot(doc))
      assertEqualInt(kids.count, 3, "mixed: text + element + text")
    }
  }
}

func testErrorMismatched(): Unit {
  match parseXml("<a><b></a>") {
    case Err(e) -> {
      val msg = XmlError.message(e)
      assertTrue(msg.length > 0, "mismatched tag error has message")
    }
    case Ok(_) -> assertTrue(false, "should fail on mismatched tags")
  }
}

func testErrorEmpty(): Unit {
  match parseXml("") {
    case Err(e) -> assertTrue(XmlError.message(e).length > 0, "empty doc error")
    case Ok(_) -> assertTrue(false, "empty doc should fail")
  }
}

func testElementChildren(): Unit {
  match parseXml("<ul><li/><li/><li/></ul>") {
    case Err(e) -> assertTrue(false, "children: " + XmlError.message(e))
    case Ok(doc) -> {
      val root = documentRoot(doc)
      assertEqualInt(elementChildren(root).count, 3, "three li children")
      assertEqualInt(elementChildren(elementChildren(root)[0]).count, 0, "li has no children")
    }
  }
}

// ── Depth guard (#583) ─────────────────────────────────────────────────────────
func testXmlDepthGuard(): Unit {
  // 2000 nested elements must be rejected by the depth guard.
  var open = ""
  var close = ""
  var d = 0
  while d < 2000 {
    open = open + "<a>"
    close = "</" + "a>" + close
    d = d + 1
  }
  match parseXml(open + close) {
    case Err(e) -> assertTrue(XmlError.message(e).length > 0, "XML depth guard fires on 2000-deep document")
    case Ok(_) -> assertTrue(false, "2000-deep XML must be rejected")
  }
}

func testXmlDepthBoundary(): Unit {
  // A shallow document (100 levels) is well within the depth limit.
  var open = ""
  var close = ""
  var d = 0
  while d < 100 {
    open = open + "<a>"
    close = "</" + "a>" + close
    d = d + 1
  }
  match parseXml(open + close) {
    case Err(e) -> assertTrue(false, "100-deep XML should parse: " + XmlError.message(e))
    case Ok(_) -> assertTrue(true, "100-deep XML parsed ok")
  }
}

func main(): Unit {
  testSelfClosing()
  testTextContent()
  testAttributes()
  testNestedElements()
  testDeepNesting()
  testEntityRefs()
  testNumericEntities()
  testEntityInAttr()
  testComment()
  testCData()
  testXmlDeclaration()
  testDocType()
  testFindFirst()
  testFindAll()
  testMixedContent()
  testErrorMismatched()
  testErrorEmpty()
  testElementChildren()
  testXmlDepthGuard()
  testXmlDepthBoundary()
  println("xml_tests: ok")
}
