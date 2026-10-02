//! wasm_glue.l — Lyric.WasmGlue: the JS glue and TypeScript declarations for
//! the wasm32 `module` shape (docs/35 §4, phase W3).
//!
//! `collectWasmExports` decides which of the entry package's `pub func`s a JS
//! caller can reach: those whose parameters and result are `Int`, `Long`,
//! `Bool`, `Byte`, `Float`, `Double`, `String` or `Unit` (an `async func`'s
//! declared or `Async[T]` result), which are neither generic, overloaded nor
//! use `out`/`inout` parameters; an async one becomes a Promise.  Every other
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
  /// An `async func`: the wasm export returns a task and the glue wrapper
  /// returns a Promise settled from host timers.
  isAsync: Bool
}

/// A host import: an `extern func` marked `@wasmImport("module")`.  The wasm
/// module imports `module`.`name`; the glue wraps the JS function the host
/// passes in `options.imports[module][name]`, decoding arguments by kind and
/// encoding the result.
pub record WasmImport {
  module: String
  name: String
  paramNames: List[String]
  params: List[String]
  ret: String
}

pub record WasmExportSet {
  /// Host imports declared by the program's own packages.
  imports: List[WasmImport]
  /// `N0014` errors for imports whose signature the glue cannot carry.
  importErrors: List[String]
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

/// The result kind of `fn`: the declared type, unwrapping an `Async[T]` /
/// `Task[T]` annotation; "Unit" when none was declared; "" when unsupported.
func resultKindOf(fn: in FunctionDecl): String {
  match fn.ret {
    case None -> "Unit"
    case Some(t) -> match t.kind {
      case TGenericApp(head, args) -> {
        val n = segLast(head)
        if (n == "Async" or n == "Task") and args.count == 1 {
          match args[0] {
            case TAType(inner) -> return kindOf(inner)
            case _ -> return ""
          }
        }
        ""
      }
      case _ -> kindOf(t)
    }
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
    if kindOf(p.ty).length == 0 or kindOf(p.ty) == "Unit" {
      return "parameter '" + p.name + "' has a type the module shape cannot pass"
    }
    i = i + 1
  }
  if resultKindOf(fn).length == 0 {
    return "its result type is not one the module shape can return"
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
        val ret = resultKindOf(fn)
        exports.add(
          WasmExport(
            jsName = fn.name,
            wasmName = unit.pkgName + "." + fn.name,
            paramNames = names,
            params = params,
            ret = ret,
            isAsync = fn.isAsync
          )
        )
      }
    }
    i = i + 1
  }
  val noImports: List[WasmImport] = newList()
  val noImportErrors: List[String] = newList()
  WasmExportSet(imports = noImports, importErrors = noImportErrors, exports = exports, notes = notes, hasMain = hasMain)
}

/// The host imports of one unit, with `N0014` errors for unsupported signatures.
func collectUnitImports(unit: in CodegenUnit, imports: in List[WasmImport], errors: in List[String]): Unit {
  for ef in unit.externs {
    val problem = wasmImportProblem(unit.wasmImports, ef.symbol)
    if problem.length > 0 {
      errors.add("error[N0014]: @wasmImport extern func " + unit.pkgName + "." + ef.name + ": " + problem)
      continue
    }
    val module = wasmImportModule(unit.wasmImports, ef.symbol)
    if module.length == 0 {
      continue
    }
    val params: List[String] = newList()
    val names: List[String] = newList()
    var ok = true
    var pi = 0
    while pi < ef.params.count {
      val k = kindOf(ef.params[pi].ty)
      if k.length == 0 or k == "Unit" {
        ok = false
      }
      params.add(k)
      names.add(ef.params[pi].name)
      pi = pi + 1
    }
    val ret = match ef.ret { case Some(t) -> kindOf(t); case None -> "Unit" }
    if ret.length == 0 {
      ok = false
    }
    if ok {
      imports.add(WasmImport(module = module, name = ef.symbol, paramNames = names, params = params, ret = ret))
    } else {
      errors.add(
        "error[N0014]: @wasmImport extern func " + unit.pkgName + "." + ef.name +
          " has a parameter or result type the host import ABI cannot carry (Int, Long, Bool, Byte, Float, Double, String, Unit)"
      )
    }
  }
}

/// The exports of the program's own units (`units[0 until ownUnits]`).  Two
/// packages exporting the same bare name keep the first and note the second.
pub func collectWasmExportsOf(units: in List[CodegenUnit], ownUnits: in Int): WasmExportSet {
  collectWasmExportsOfShaped(units, ownUnits, false)
}

/// As `collectWasmExportsOf`; `perPackage` scopes the duplicate-name check to
/// one package (the component shape renders one WIT interface per package, so
/// the same name in two packages is not ambiguous there).
pub func collectWasmExportsOfShaped(units: in List[CodegenUnit], ownUnits: in Int, perPackage: in Bool): WasmExportSet {
  val exports: List[WasmExport] = newList()
  val notes: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  val imports: List[WasmImport] = newList()
  val importErrors: List[String] = newList()
  var hasMain = false
  var u = 0
  while u < ownUnits and u < units.count {
    collectUnitImports(units[u], imports, importErrors)
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
      val key = if perPackage { e.wasmName } else { e.jsName }
      if seen.containsKey(key) {
        notes.add(
          "warning[W0040]: pub func " + e.wasmName + " is not exported to JS: another package already exports '" + e.jsName +
            "'"
        )
      } else {
        seen.add(key, true)
        exports.add(e)
      }
      ei = ei + 1
    }
    u = u + 1
  }
  WasmExportSet(imports = imports, importErrors = importErrors, exports = exports, notes = notes, hasMain = hasMain)
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
        (if e.isAsync { ", async: true" } else { "" }) +
        " }"
    )
    i = i + 1
  }
  if rows.count == 0 {
    return "const LYRIC_EXPORTS = [];\n"
  }
  "const LYRIC_EXPORTS = [\n" + Str.joinList(",\n", rows) + ",\n];\n"
}

func importTableJs(set: in WasmExportSet): String {
  val rows: List[String] = newList()
  for imp in set.imports {
    val ps: List[String] = newList()
    for k in imp.params {
      ps.add(jsString(k))
    }
    rows.add(
      "  { module: " + jsString(imp.module) + ", name: " + jsString(imp.name) + ", params: [" + Str.joinList(", ", ps) +
        "], ret: " +
        jsString(imp.ret) +
        " }"
    )
  }
  if rows.count == 0 {
    return "const LYRIC_IMPORTS = [];\n"
  }
  "const LYRIC_IMPORTS = [\n" + Str.joinList(",\n", rows) + ",\n];\n"
}

/// The generated ES module: header, export and import tables, then the static runtime.
pub func renderGlueModule(set: in WasmExportSet, wasmFileName: in String): String {
  "// Generated by `lyric build --shape module` (docs/35 W3). Do not edit.\n" + "export const wasmFile = " +
    jsString(wasmFileName) +
    ";\n" +
    exportTableJs(set) +
    importTableJs(set) +
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
    val tsRet = if e.isAsync { "Promise<" + tsType(e.ret) + ">" } else { tsType(e.ret) }
    members.add("  " + e.jsName + "(" + Str.joinList(", ", ps) + "): " + tsRet + ";")
    i = i + 1
  }
  if set.hasMain {
    members.add("  run(args?: string[]): number;")
  }
  members.add("  flush(): void;")
  members.add("  readonly memory: WebAssembly.Memory;")
  members.add("  readonly raw: WebAssembly.Exports;")
  val hostModules: List[String] = newList()
  val seenModules: Map[String, Bool] = newMap()
  for imp in set.imports {
    if not seenModules.containsKey(imp.module) {
      seenModules.add(imp.module, true)
      val fns: List[String] = newList()
      for other in set.imports {
        if other.module == imp.module {
          val ps: List[String] = newList()
          var pi = 0
          while pi < other.params.count {
            ps.add(other.paramNames[pi] + ": " + tsType(other.params[pi]))
            pi = pi + 1
          }
          fns.add("    " + other.name + "(" + Str.joinList(", ", ps) + "): " + tsType(other.ret) + ";")
        }
      }
      hostModules.add("  " + jsString(imp.module) + ": {\n" + Str.joinList("\n", fns) + "\n  };")
    }
  }
  val hostInterface = if hostModules.count == 0 {
    ""
  } else {
    "export interface LyricHostImports {\n" + Str.joinList("\n", hostModules) + "\n}\n"
  }
  val importsMember = if hostModules.count == 0 {
    "  imports?: Record<string, Record<string, WebAssembly.ImportValue>>;\n"
  } else {
    "  imports: LyricHostImports & Record<string, Record<string, unknown>>;\n"
  }
  val optionsMark = if hostModules.count == 0 { "?" } else { "" }
  "// Generated by `lyric build --shape module` (docs/35 W3). Do not edit.\n" + "export const wasmFile: string;\n" +
    "export class LyricExit extends Error {\n  constructor(code: number);\n  readonly code: number;\n}\n" +
    hostInterface +
    "export interface LyricInstantiateOptions {\n" +
    "  stdout?: (text: string) => void;\n" +
    "  stderr?: (text: string) => void;\n" +
    "  stdin?: () => string | Uint8Array | null;\n" +
    "  args?: string[];\n" +
    "  env?: Record<string, string>;\n" +
    importsMember +
    "}\n" +
    "export interface LyricModule {\n" +
    Str.joinList("\n", members) +
    "\n}\n" +
    "export function instantiate(\n  source?: ArrayBuffer | ArrayBufferView | URL | string | Response | Promise<Response> | WebAssembly.Module,\n  options" +
    optionsMark +
    ": LyricInstantiateOptions,\n): Promise<LyricModule>;\n"
}

/// Names the generated JS glue object already uses.  An export with one of these
/// names would overwrite the member (`run`, `memory`, `flush`, `raw`) or make the
/// `instantiate()` result thenable (`then`), so it is left out with a `W0040`.
func isReservedJsName(name: in String): Bool {
  name == "run" or name == "memory" or name == "flush" or name == "raw" or name == "then"
}

/// `set` without the exports whose names the JS glue object reserves (module shape).
pub func withoutReservedJsNames(set: in WasmExportSet): WasmExportSet {
  val kept: List[WasmExport] = newList()
  val notes: List[String] = newList()
  for n in set.notes {
    notes.add(n)
  }
  for e in set.exports {
    if isReservedJsName(e.jsName) {
      notes.add(
        "warning[W0040]: pub func " + e.wasmName + " is not exported to JS: '" + e.jsName +
          "' is a member of the generated glue object; rename the function"
      )
    } else {
      kept.add(e)
    }
  }
  WasmExportSet(
    imports = set.imports,
    importErrors = set.importErrors,
    exports = kept,
    notes = notes,
    hasMain = set.hasMain
  )
}
