//! wasm_glue.l — Lyric.WasmGlue: the JS glue and TypeScript declarations for
//! the wasm32 `module` shape (docs/35 §4, phase W3).
//!
//! `collectWasmExports` decides which of the entry package's `pub func`s a JS
//! caller can reach: those whose parameters and result are `Int`, `Long`,
//! `Bool`, `Byte`, `Float`, `Double`, `String` or `Unit`, which are neither
//! generic, `async`, overloaded nor use `out`/`inout` parameters.  Every other
//! `pub func` is reported as a `W0040` note and left out; no function is
//! silently dropped.  `renderGlueModule` prepends the generated export table to
//! the static runtime (`Lyric.WasmGlueRuntime`), and `renderGlueTypes` writes
//! the matching `.d.ts`.
package Lyric.WasmGlue

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Parser
import Lyric.LlvmCodegen
import Lyric.WasmGlueRuntime

/// One exported function: `jsName` is the property on the instantiated module,
/// `wasmName` the wasm export (`Pkg.name`, the symbol the native backend emits),
/// and `params`/`ret` use the kind names the glue runtime switches on.
pub record WasmExport {
  jsName: String
  wasmName: String
  paramNames: List[String]
  params: List[String]
  ret: String
}

pub record WasmExportSet {
  exports: List[WasmExport]
  /// `W0040` notes for the `pub func`s left out, ready to print.
  notes: List[String]
  /// The package declares `func main(): Int`, so the module exports
  /// `__main_argc_argv` and the glue gains `run()`.
  hasMain: Bool
}

func segLast(path: in ModulePath): String {
  if path.segments.count == 0 {
    return ""
  }
  path.segments[path.segments.count - 1]
}

/// The kind name for a supported type, or "" for any other type.
func kindOf(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> {
      val n = segLast(path)
      if n == "Int" or n == "Long" or n == "Bool" or n == "Byte" or n == "Float" or n == "Double" or n == "String" or n == "Unit" {
        return n
      }
      ""
    }
    case TUnit -> "Unit"
    case TParen(inner) -> kindOf(inner)
    case _ -> ""
  }
}

func isPubFn(fn: in FunctionDecl): Bool {
  match fn.visibility {
    case Some(VisPub(_)) -> true
    case _ -> false
  }
}

func sameNameCount(unit: in CodegenUnit, name: in String): Int {
  var n = 0
  var i = 0
  while i < unit.fns.count {
    if unit.fns[i].name == name {
      n = n + 1
    }
    i = i + 1
  }
  n
}

func hasGenerics(fn: in FunctionDecl): Bool {
  match fn.generics {
    case Some(_) -> true
    case None -> false
  }
}

/// Why `fn` cannot be exported, or "" when it can.
func exclusionReason(unit: in CodegenUnit, fn: in FunctionDecl): String {
  if hasGenerics(fn) {
    return "it is generic"
  }
  if fn.isAsync {
    return "it is async"
  }
  if sameNameCount(unit, fn.name) > 1 {
    return "it is overloaded"
  }
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    match p.mode {
      case PMIn -> ()
      case _ -> return "parameter '" + p.name + "' is out/inout"
    }
    if kindOf(p.ty).length == 0 {
      return "parameter '" + p.name + "' has a type the module shape cannot pass"
    }
    i = i + 1
  }
  match fn.ret {
    case Some(t) -> {
      if kindOf(t).length == 0 {
        return "its result type is not one the module shape can return"
      }
    }
    case None -> ()
  }
  ""
}

/// The exports of the entry package's unit.
pub func collectWasmExports(unit: in CodegenUnit): WasmExportSet {
  val exports: List[WasmExport] = newList()
  val notes: List[String] = newList()
  var hasMain = false
  var i = 0
  while i < unit.fns.count {
    val fn = unit.fns[i]
    if fn.name == "main" and fn.params.count == 0 {
      hasMain = true
    }
    if isPubFn(fn) {
      val why = exclusionReason(unit, fn)
      if why.length > 0 {
        notes.add("warning[W0040]: pub func " + unit.pkgName + "." + fn.name + " is not exported to JS: " + why)
      } else {
        val params: List[String] = newList()
        val names: List[String] = newList()
        var pi = 0
        while pi < fn.params.count {
          params.add(kindOf(fn.params[pi].ty))
          names.add(fn.params[pi].name)
          pi = pi + 1
        }
        val ret = match fn.ret { case Some(t) -> kindOf(t); case None -> "Unit" }
        exports.add(
          WasmExport(
            jsName = fn.name,
            wasmName = unit.pkgName + "." + fn.name,
            paramNames = names,
            params = params,
            ret = ret
          )
        )
      }
    }
    i = i + 1
  }
  WasmExportSet(exports = exports, notes = notes, hasMain = hasMain)
}

/// The exports of the program's own units (`units[0 until ownUnits]`).  Two
/// packages exporting the same bare name keep the first and note the second.
pub func collectWasmExportsOf(units: in List[CodegenUnit], ownUnits: in Int): WasmExportSet {
  val exports: List[WasmExport] = newList()
  val notes: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  var hasMain = false
  var u = 0
  while u < ownUnits and u < units.count {
    val one = collectWasmExports(units[u])
    if one.hasMain {
      hasMain = true
    }
    var ni = 0
    while ni < one.notes.count {
      notes.add(one.notes[ni])
      ni = ni + 1
    }
    var ei = 0
    while ei < one.exports.count {
      val e = one.exports[ei]
      if seen.containsKey(e.jsName) {
        notes.add(
          "warning[W0040]: pub func " + e.wasmName + " is not exported to JS: another package already exports '" + e.jsName +
            "'"
        )
      } else {
        seen.add(e.jsName, true)
        exports.add(e)
      }
      ei = ei + 1
    }
    u = u + 1
  }
  WasmExportSet(exports = exports, notes = notes, hasMain = hasMain)
}

func jsString(s: in String): String {
  var buf = "\""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '"' {
      buf = buf + "\\\""
    } else if c == '\\' {
      buf = buf + "\\\\"
    } else {
      buf = buf + c.toString()
    }
    i = i + 1
  }
  buf + "\""
}

func exportTableJs(set: in WasmExportSet): String {
  val rows: List[String] = newList()
  var i = 0
  while i < set.exports.count {
    val e = set.exports[i]
    val ps: List[String] = newList()
    var pi = 0
    while pi < e.params.count {
      ps.add(jsString(e.params[pi]))
      pi = pi + 1
    }
    rows.add(
      "  { js: " + jsString(e.jsName) + ", wasm: " + jsString(e.wasmName) + ", params: [" + Str.joinList(", ", ps) +
        "], ret: " +
        jsString(e.ret) +
        " }"
    )
    i = i + 1
  }
  if rows.count == 0 {
    return "const LYRIC_EXPORTS = [];\n"
  }
  "const LYRIC_EXPORTS = [\n" + Str.joinList(",\n", rows) + ",\n];\n"
}

/// The generated ES module: header, export table, then the static runtime.
pub func renderGlueModule(set: in WasmExportSet, wasmFileName: in String): String {
  "// Generated by `lyric build --shape module` (docs/35 W3). Do not edit.\n" + "export const wasmFile = " +
    jsString(wasmFileName) +
    ";\n" +
    exportTableJs(set) +
    "\n" +
    glueRuntimeJs()
}

func tsType(kind: in String): String {
  match kind {
    case "Long" -> "bigint"
    case "Bool" -> "boolean"
    case "String" -> "string"
    case "Unit" -> "void"
    case _ -> "number"
  }
}

/// The `.d.ts` matching `renderGlueModule`'s output.
pub func renderGlueTypes(set: in WasmExportSet): String {
  val members: List[String] = newList()
  var i = 0
  while i < set.exports.count {
    val e = set.exports[i]
    val ps: List[String] = newList()
    var pi = 0
    while pi < e.params.count {
      ps.add(e.paramNames[pi] + ": " + tsType(e.params[pi]))
      pi = pi + 1
    }
    members.add("  " + e.jsName + "(" + Str.joinList(", ", ps) + "): " + tsType(e.ret) + ";")
    i = i + 1
  }
  if set.hasMain {
    members.add("  run(args?: string[]): number;")
  }
  members.add("  flush(): void;")
  members.add("  readonly memory: WebAssembly.Memory;")
  members.add("  readonly raw: WebAssembly.Exports;")
  "// Generated by `lyric build --shape module` (docs/35 W3). Do not edit.\n" + "export const wasmFile: string;\n" +
    "export class LyricExit extends Error {\n  constructor(code: number);\n  readonly code: number;\n}\n" +
    "export interface LyricInstantiateOptions {\n" +
    "  stdout?: (text: string) => void;\n" +
    "  stderr?: (text: string) => void;\n" +
    "  stdin?: () => string | Uint8Array | null;\n" +
    "  args?: string[];\n" +
    "  env?: Record<string, string>;\n" +
    "  imports?: Record<string, Record<string, WebAssembly.ImportValue>>;\n" +
    "}\n" +
    "export interface LyricModule {\n" +
    Str.joinList("\n", members) +
    "\n}\n" +
    "export function instantiate(\n  source?: ArrayBuffer | ArrayBufferView | URL | string | Response | Promise<Response> | WebAssembly.Module,\n  options?: LyricInstantiateOptions,\n): Promise<LyricModule>;\n"
}
