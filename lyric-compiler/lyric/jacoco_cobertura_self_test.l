//! jacoco_cobertura_self_test.l — regression coverage for
//! `Lyric.JacocoCobertura.jacocoXmlToCobertura` (`lyric test --target jvm
//! --coverage`'s JaCoCo XML -> Cobertura XML converter).
//!
//! The primary fixture (`realJacocoReport`) is a byte-for-byte JaCoCo
//! 0.8.12 XML report, captured by actually running `jacococli.jar report`
//! against a real instrumented run of a small Java program (two branches,
//! one constructor, one covered method, one partially-covered method) —
//! not a hand-imagined shape. The expected Cobertura values below were
//! computed by hand from that same fixture, so this test would fail if the
//! converter's counter/line-mapping logic drifted from JaCoCo's real schema.
@test_module
package Lyric.JacocoCoberturaSelfTest

import Std.Core
import Std.Testing
import Std.String as Str
import Lyric.JacocoCobertura as Jc

val realJacocoReport: String = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><!DOCTYPE report PUBLIC "-//JACOCO//DTD Report 1.1//EN" "report.dtd"><report name="FooReport"><sessioninfo id="vm-17f3020b" start="1787788391060" dump="1787788391152"/><package name="com/example"><class name="com/example/Foo" sourcefilename="Foo.java"><method name="&lt;init&gt;" desc="()V" line="2"><counter type="INSTRUCTION" missed="3" covered="0"/><counter type="LINE" missed="1" covered="0"/><counter type="COMPLEXITY" missed="1" covered="0"/><counter type="METHOD" missed="1" covered="0"/></method><method name="add" desc="(II)I" line="4"><counter type="INSTRUCTION" missed="2" covered="6"/><counter type="BRANCH" missed="1" covered="1"/><counter type="LINE" missed="1" covered="2"/><counter type="COMPLEXITY" missed="1" covered="1"/><counter type="METHOD" missed="0" covered="1"/></method><method name="main" desc="([Ljava/lang/String;)V" line="11"><counter type="INSTRUCTION" missed="0" covered="6"/><counter type="LINE" missed="0" covered="2"/><counter type="COMPLEXITY" missed="0" covered="1"/><counter type="METHOD" missed="0" covered="1"/></method><counter type="INSTRUCTION" missed="5" covered="12"/><counter type="BRANCH" missed="1" covered="1"/><counter type="LINE" missed="2" covered="4"/><counter type="COMPLEXITY" missed="2" covered="2"/><counter type="METHOD" missed="1" covered="2"/><counter type="CLASS" missed="0" covered="1"/></class><sourcefile name="Foo.java"><line nr="2" mi="3" ci="0" mb="0" cb="0"/><line nr="4" mi="0" ci="2" mb="1" cb="1"/><line nr="5" mi="0" ci="4" mb="0" cb="0"/><line nr="7" mi="2" ci="0" mb="0" cb="0"/><line nr="11" mi="0" ci="5" mb="0" cb="0"/><line nr="12" mi="0" ci="1" mb="0" cb="0"/><counter type="INSTRUCTION" missed="5" covered="12"/><counter type="BRANCH" missed="1" covered="1"/><counter type="LINE" missed="2" covered="4"/><counter type="COMPLEXITY" missed="2" covered="2"/><counter type="METHOD" missed="1" covered="2"/><counter type="CLASS" missed="0" covered="1"/></sourcefile><counter type="INSTRUCTION" missed="5" covered="12"/><counter type="BRANCH" missed="1" covered="1"/><counter type="LINE" missed="2" covered="4"/><counter type="COMPLEXITY" missed="2" covered="2"/><counter type="METHOD" missed="1" covered="2"/><counter type="CLASS" missed="0" covered="1"/></package><counter type="INSTRUCTION" missed="5" covered="12"/><counter type="BRANCH" missed="1" covered="1"/><counter type="LINE" missed="2" covered="4"/><counter type="COMPLEXITY" missed="2" covered="2"/><counter type="METHOD" missed="1" covered="2"/><counter type="CLASS" missed="0" covered="1"/></report>"""

test "converts package and class names from slash to dotted form" {
  match Jc.jacocoXmlToCobertura(realJacocoReport) {
    case Ok(xml) -> {
      assertTrue(Str.contains(xml, "<package name=\"com.example\""), "package name dotted")
      assertTrue(Str.contains(xml, "<class name=\"com.example.Foo\""), "class name dotted")
      assertTrue(Str.contains(xml, "filename=\"com/example/Foo.java\""), "filename keeps slash form")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "computes class line-rate and branch-rate from JaCoCo LINE/BRANCH counters" {
  match Jc.jacocoXmlToCobertura(realJacocoReport) {
    case Ok(xml) -> {
      // class LINE counter: missed=2 covered=4 -> 4/6 = 0.6667
      assertTrue(Str.contains(xml, "line-rate=\"0.6667\""), "class line-rate 4/6")
      // class BRANCH counter: missed=1 covered=1 -> 1/2 = 0.5
      assertTrue(Str.contains(xml, "branch-rate=\"0.5000\""), "class branch-rate 1/2")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "maps covered/uncovered lines to hits=1/hits=0 and marks branch lines" {
  match Jc.jacocoXmlToCobertura(realJacocoReport) {
    case Ok(xml) -> {
      // nr=2 ci=0 -> uncovered constructor line
      assertTrue(Str.contains(xml, "<line number=\"2\" hits=\"0\" branch=\"false\"/>"), "line 2 uncovered")
      // nr=4 ci=2 mb=1 cb=1 -> covered branch line
      assertTrue(Str.contains(xml, "<line number=\"4\" hits=\"1\" branch=\"true\"/>"), "line 4 covered branch")
      // nr=7 mi=2 ci=0 -> uncovered else-branch line
      assertTrue(Str.contains(xml, "<line number=\"7\" hits=\"0\" branch=\"false\"/>"), "line 7 uncovered")
      // nr=11 ci=5 -> covered
      assertTrue(Str.contains(xml, "<line number=\"11\" hits=\"1\" branch=\"false\"/>"), "line 11 covered")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "aggregates report-level totals from the single package's counters" {
  match Jc.jacocoXmlToCobertura(realJacocoReport) {
    case Ok(xml) -> {
      assertTrue(Str.contains(xml, "lines-covered=\"4\""), "total lines-covered")
      assertTrue(Str.contains(xml, "lines-valid=\"6\""), "total lines-valid")
      assertTrue(Str.contains(xml, "branches-covered=\"1\""), "total branches-covered")
      assertTrue(Str.contains(xml, "branches-valid=\"2\""), "total branches-valid")
      assertTrue(Str.contains(xml, "timestamp=\"1787788391152\""), "timestamp from sessioninfo dump")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "emits method-level line-rate/branch-rate from per-method counters" {
  match Jc.jacocoXmlToCobertura(realJacocoReport) {
    case Ok(xml) -> {
      // add(): LINE missed=1 covered=2 -> 2/3 = 0.6667; BRANCH missed=1 covered=1 -> 0.5
      assertTrue(
        Str.contains(xml, "<method name=\"add\" signature=\"(II)I\" line-rate=\"0.6667\" branch-rate=\"0.5000\">"),
        "add() method rates"
      )
      // main(): LINE missed=0 covered=2 -> 1.0; no BRANCH counter -> 1.0
      assertTrue(
        Str.contains(
          xml,
          "<method name=\"main\" signature=\"([Ljava/lang/String;)V\" line-rate=\"1.0000\" branch-rate=\"1.0000\">"
        ),
        "main() method rates, no-branch default"
      )
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "non-report root is rejected as MissingReportRoot" {
  match Jc.jacocoXmlToCobertura("<notareport/>") {
    case Ok(unexpected) -> assertTrue(false, "expected MissingReportRoot error, got Ok: [" + unexpected + "]")
    case Err(e) -> {
      match e {
        case MissingReportRoot -> assertTrue(true, "got MissingReportRoot")
        case XmlParseError(m) -> assertTrue(false, "expected MissingReportRoot, got XmlParseError: " + m)
      }
    }
  }
}

test "malformed XML is rejected as XmlParseError" {
  match Jc.jacocoXmlToCobertura("<report><package name=\"x\"") {
    case Ok(_) -> assertTrue(false, "expected XmlParseError")
    case Err(e) -> {
      match e {
        case XmlParseError(_) -> assertTrue(true, "got XmlParseError")
        case MissingReportRoot -> assertTrue(false, "expected XmlParseError, got MissingReportRoot")
      }
    }
  }
}

test "aggregates totals across multiple packages" {
  val twoPkgReport = "<report name=\"R\">" +
    "<package name=\"a\"><counter type=\"LINE\" missed=\"1\" covered=\"1\"/><counter type=\"BRANCH\" missed=\"0\" covered=\"0\"/></package>" +
    "<package name=\"b\"><counter type=\"LINE\" missed=\"0\" covered=\"2\"/><counter type=\"BRANCH\" missed=\"0\" covered=\"0\"/></package>" +
    "</report>"
  match Jc.jacocoXmlToCobertura(twoPkgReport) {
    case Ok(xml) -> {
      // package a: 1 covered, 1 missed; package b: 2 covered, 0 missed -> total 3 covered, 1 missed
      assertTrue(Str.contains(xml, "lines-covered=\"3\""), "aggregated lines-covered across packages")
      assertTrue(Str.contains(xml, "lines-valid=\"4\""), "aggregated lines-valid across packages")
      assertTrue(Str.contains(xml, "<package name=\"a\""), "package a present")
      assertTrue(Str.contains(xml, "<package name=\"b\""), "package b present")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}

test "a branch-free class reports branch-rate 1.0 rather than dividing by zero" {
  val noBranchReport = "<report name=\"R\">" + "<package name=\"p\">" +
    "<class name=\"p/NoBranch\" sourcefilename=\"NoBranch.java\">" +
    "<counter type=\"LINE\" missed=\"0\" covered=\"3\"/>" +
    "</class>" +
    "<sourcefile name=\"NoBranch.java\"/>" +
    "</package></report>"
  match Jc.jacocoXmlToCobertura(noBranchReport) {
    case Ok(xml) -> {
      assertTrue(
        Str.contains(xml, "line-rate=\"1.0000\" branch-rate=\"1.0000\""),
        "no-branch class defaults branch-rate to 1.0"
      )
    }
    case Err(e) -> assertTrue(false, "expected Ok, got: " + e.message())
  }
}
