//! component_glue.l — Lyric.ComponentGlue: the WIT and canonical-ABI wrappers
//! of the wasm32 `component` shape (docs/35 §7, phase W4).
//!
//! The exports are the ones `Lyric.WasmGlue.collectWasmExportsOf` finds, minus
//! those the canonical ABI layer cannot lift yet.  `renderWit` writes the WIT
//! package (one interface per exporting Lyric package, one world); `renderCabi`
//! writes a C file that the native link compiles in: for each export it lifts
//! the canonical-ABI arguments (a `string` is a pointer and a length the caller
//! allocated through `cabi_realloc`, and the callee frees), calls the Lyric
//! function, and lowers the result (a `string` result is returned through a
//! return area, with a `cabi_post_` function that frees the bytes).  Generating C
//! keeps the wrappers independent of the runtime's headers: they use only the
//! `lyric_wasm_*` helper ABI.
package Lyric.ComponentGlue

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch
import Lyric.WasmGlue

/// WIT's reserved words, which a Lyric name must escape with `%`.
func isWitKeyword(w: in String): Bool {
  w == "use" or w == "type" or w == "func" or w == "u8" or w == "u16" or w == "u32" or w == "u64" or w == "s8" or
    w == "s16" or w == "s32" or w == "s64" or w == "f32" or w == "f64" or w == "char" or w == "record" or
    w == "flags" or w == "variant" or w == "enum" or w == "bool" or w == "string" or w == "option" or
    w == "result" or w == "list" or w == "tuple" or w == "as" or w == "from" or w == "static" or w == "interface" or
    w == "world" or w == "import" or w == "export" or w == "package" or w == "constructor" or w == "include" or
    w == "with" or w == "resource" or w == "own" or w == "borrow" or w == "future" or w == "stream"
}

func isUpperCh(c: in Char): Bool {
  c >= 'A' and c <= 'Z'
}

func isLowerCh(c: in Char): Bool {
  c >= 'a' and c <= 'z'
}

func isDigitCh(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func lowerCh(c: in Char): String {
  if isUpperCh(c) {
    Ch.asciiToLower(c).toString()
  } else {
    c.toString()
  }
}

/// A Lyric identifier as a WIT kebab-case name: `customerId`, `customer_id` and
/// `CustomerId` become `customer-id`; an acronym stays one word (`IOError` is
/// `io-error`).  A name that is a WIT keyword is escaped with `%`.
pub func witName(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val prev = if i > 0 { Str.charAtOrReplacement(s, i - 1) } else { ' ' }
    val next = if i + 1 < s.length { Str.charAtOrReplacement(s, i + 1) } else { ' ' }
    if c == '_' or c == '.' or c == '-' {
      if acc.length > 0 and not Str.endsWith(acc, "-") {
        acc = acc + "-"
      }
    } else if isUpperCh(c) {
      val boundary = isLowerCh(prev) or isDigitCh(prev) or (isUpperCh(prev) and isLowerCh(next))
      if boundary and acc.length > 0 and not Str.endsWith(acc, "-") {
        acc = acc + "-"
      }
      acc = acc + lowerCh(c)
    } else {
      acc = acc + c.toString()
    }
    i = i + 1
  }
  if isWitKeyword(acc) {
    "%" + acc
  } else {
    acc
  }
}

/// The WIT type for a kind, "" for `Unit`.
func witType(kind: in String): String {
  match kind {
    case "Int" -> "s32"
    case "Long" -> "s64"
    case "Bool" -> "bool"
    case "Byte" -> "u8"
    case "Float" -> "f32"
    case "Double" -> "f64"
    case "String" -> "string"
    case _ -> ""
  }
}

/// How many core wasm values a kind flattens to as a parameter.
func flatWidth(kind: in String): Int {
  if kind == "String" {
    2
  } else {
    1
  }
}

/// The Lyric package an export belongs to (`wasmName` is `Pkg.name`).
func pkgOf(e: in WasmExport): String {
  Str.substring(e.wasmName, 0, e.wasmName.length - e.jsName.length - 1)
}

/// The canonical ABI passes at most 16 flat parameters; more spill to memory,
/// which this layer does not implement.  Returns why `e` cannot be lifted, or "".
func liftBlocker(e: in WasmExport): String {
  if e.isAsync {
    return "an async export needs the component async ABI (docs/35 Q-JS-006)"
  }
  var width = 0
  for p in e.params {
    width = width + flatWidth(p)
  }
  if width > 16 {
    return "it has more than 16 flat parameters"
  }
  ""
}

pub record ComponentExports {
  exports: List[WasmExport]
  notes: List[String]
}

/// The exports the component shape can carry, with `W0040` notes for the rest.
pub func componentExportsOf(set: in WasmExportSet): ComponentExports {
  val kept: List[WasmExport] = newList()
  val notes: List[String] = newList()
  for e in set.exports {
    val why = liftBlocker(e)
    if why.length > 0 {
      notes.add("warning[W0040]: pub func " + e.wasmName + " is not exported to the component: " + why)
    } else {
      kept.add(e)
    }
  }
  ComponentExports(exports = kept, notes = notes)
}

/// The distinct Lyric packages of `exports`, in first-seen order.
func packagesOf(exports: in List[WasmExport]): List[String] {
  val pkgs: List[String] = newList()
  for e in exports {
    val p = pkgOf(e)
    var seen = false
    for q in pkgs {
      if q == p {
        seen = true
      }
    }
    if not seen {
      pkgs.add(p)
    }
  }
  pkgs
}

/// `lyric:<package>@<version>`, named for the first exporting Lyric package.
pub func witPackageName(exports: in List[WasmExport], version: in String): String {
  val pkgs = packagesOf(exports)
  val first = if pkgs.count > 0 { pkgs[0] } else { "program" }
  "lyric:" + witName(first) + "@" + version
}

/// The world name: `<package>-world`.
pub func witWorldName(exports: in List[WasmExport]): String {
  val pkgs = packagesOf(exports)
  val first = if pkgs.count > 0 { pkgs[0] } else { "program" }
  witName(first) + "-world"
}

/// The WIT document for `exports` (docs/35 §7.2).
pub func renderWit(exports: in List[WasmExport], version: in String): String {
  val pkgs = packagesOf(exports)
  val parts: List[String] = newList()
  parts.add("package " + witPackageName(exports, version) + ";\n")
  for pkg in pkgs {
    val lines: List[String] = newList()
    for e in exports {
      if pkgOf(e) == pkg {
        val ps: List[String] = newList()
        var pi = 0
        while pi < e.params.count {
          ps.add(witName(e.paramNames[pi]) + ": " + witType(e.params[pi]))
          pi = pi + 1
        }
        val ret = witType(e.ret)
        val tail = if ret.length > 0 { " -> " + ret } else { "" }
        lines.add("  " + witName(e.jsName) + ": func(" + Str.joinList(", ", ps) + ")" + tail + ";")
      }
    }
    parts.add("interface " + witName(pkg) + " {\n" + Str.joinList("\n", lines) + "\n}\n")
  }
  val exportLines: List[String] = newList()
  for pkg in pkgs {
    exportLines.add("  export " + witName(pkg) + ";")
  }
  parts.add("world " + witWorldName(exports) + " {\n" + Str.joinList("\n", exportLines) + "\n}\n")
  Str.joinList("\n", parts)
}

/// The C type a Lyric function takes or returns for a kind.
func cTypeOf(kind: in String): String {
  match kind {
    case "Int" -> "int32_t"
    case "Long" -> "int64_t"
    case "Bool" -> "_Bool"
    case "Byte" -> "uint8_t"
    case "Float" -> "float"
    case "Double" -> "double"
    case "String" -> "void*"
    case _ -> "void"
  }
}

/// The C type a kind has as a canonical-ABI core parameter (`bool` and `u8`
/// travel as `i32`).
func cabiParamType(kind: in String): String {
  match kind {
    case "Bool" -> "int32_t"
    case "Byte" -> "int32_t"
    case _ -> cTypeOf(kind)
  }
}

/// The core export name of a function: `<package>/<interface>#<func>`.
func coreExportName(exports: in List[WasmExport], e: in WasmExport, version: in String): String {
  "lyric:" + witName(pkgOf(exports[0])) + "/" + witName(pkgOf(e)) + "@" + version + "#" + witName(e.jsName)
}

/// The C wrappers for `exports` (see the module header).
pub func renderCabi(exports: in List[WasmExport], version: in String): String {
  val out: List[String] = newList()
  out.add("/* Generated by `lyric build --shape component` (docs/35 W4). Do not edit. */")
  out.add("#include <stdint.h>")
  out.add("#include <stdlib.h>")
  out.add("#include <string.h>")
  out.add("")
  out.add("extern void* lyric_wasm_string_new(const uint8_t*, int32_t);")
  out.add("extern int32_t lyric_wasm_string_len(void*);")
  out.add("extern const uint8_t* lyric_wasm_string_data(void*);")
  out.add("extern void lyric_wasm_release(void*);")
  out.add("")
  out.add("__attribute__((export_name(\"cabi_realloc\")))")
  out.add("void* cabi_realloc(void* old, size_t old_size, size_t align, size_t new_size) {")
  out.add("    if (new_size == 0) return (void*)align;")
  out.add("    if (old && old_size > 0) return realloc(old, new_size);")
  out.add("    return malloc(new_size);")
  out.add("}")
  out.add("")
  var n = 0
  for e in exports {
    val cname = "lyric_fn" + n.toString()
    val cparams: List[String] = newList()
    for p in e.params {
      cparams.add(cTypeOf(p))
    }
    val retC = cTypeOf(e.ret)
    out.add("extern " + retC + " " + cname + "(" + (if cparams.count == 0 { "void" } else { Str.joinList(", ", cparams) }) +
      ") __asm__(\"" + e.wasmName + "\");")
    val exportName = coreExportName(exports, e, version)
    val wparams: List[String] = newList()
    val prelude: List[String] = newList()
    val args: List[String] = newList()
    val releases: List[String] = newList()
    var pi = 0
    while pi < e.params.count {
      val k = e.params[pi]
      val v = "a" + pi.toString()
      if k == "String" {
        wparams.add("uint8_t* " + v + "_p")
        wparams.add("int32_t " + v + "_n")
        prelude.add("    void* " + v + " = lyric_wasm_string_new(" + v + "_p, " + v + "_n);")
        prelude.add("    if (" + v + "_n > 0) free(" + v + "_p);")
        args.add(v)
        releases.add("    lyric_wasm_release(" + v + ");")
      } else {
        wparams.add(cabiParamType(k) + " " + v)
        if k == "Bool" {
          args.add("(_Bool)(" + v + " != 0)")
        } else if k == "Byte" {
          args.add("(uint8_t)" + v)
        } else {
          args.add(v)
        }
      }
      pi = pi + 1
    }
    val call = cname + "(" + Str.joinList(", ", args) + ")"
    val wsig = if wparams.count == 0 { "void" } else { Str.joinList(", ", wparams) }
    out.add("")
    if e.ret == "String" {
      out.add("static int32_t cabi_ret" + n.toString() + "[2];")
      out.add("__attribute__((export_name(\"" + exportName + "\")))")
      out.add("int32_t* cabi_fn" + n.toString() + "(" + wsig + ") {")
      for l in prelude {
        out.add(l)
      }
      out.add("    void* r = " + call + ";")
      for l in releases {
        out.add(l)
      }
      out.add("    int32_t len = lyric_wasm_string_len(r);")
      out.add("    uint8_t* bytes = len > 0 ? (uint8_t*)malloc((size_t)len) : (uint8_t*)1;")
      out.add("    if (len > 0) memcpy(bytes, lyric_wasm_string_data(r), (size_t)len);")
      out.add("    lyric_wasm_release(r);")
      out.add("    cabi_ret" + n.toString() + "[0] = (int32_t)(intptr_t)bytes;")
      out.add("    cabi_ret" + n.toString() + "[1] = len;")
      out.add("    return cabi_ret" + n.toString() + ";")
      out.add("}")
      out.add("")
      out.add("__attribute__((export_name(\"cabi_post_" + exportName + "\")))")
      out.add("void cabi_post" + n.toString() + "(int32_t* ret) {")
      out.add("    if (ret[1] > 0) free((void*)(intptr_t)ret[0]);")
      out.add("}")
    } else if e.ret == "Unit" {
      out.add("__attribute__((export_name(\"" + exportName + "\")))")
      out.add("void cabi_fn" + n.toString() + "(" + wsig + ") {")
      for l in prelude {
        out.add(l)
      }
      out.add("    " + call + ";")
      for l in releases {
        out.add(l)
      }
      out.add("}")
    } else {
      val wret = cabiParamType(e.ret)
      out.add("__attribute__((export_name(\"" + exportName + "\")))")
      out.add(wret + " cabi_fn" + n.toString() + "(" + wsig + ") {")
      for l in prelude {
        out.add(l)
      }
      out.add("    " + cTypeOf(e.ret) + " r = " + call + ";")
      for l in releases {
        out.add(l)
      }
      if e.ret == "Bool" {
        out.add("    return r ? 1 : 0;")
      } else {
        out.add("    return r;")
      }
      out.add("}")
    }
    n = n + 1
  }
  Str.joinList("\n", out) + "\n"
}
