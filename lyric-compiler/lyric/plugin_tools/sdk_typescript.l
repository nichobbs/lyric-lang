//! sdk_typescript.l - Lyric.PluginSdk: the TypeScript SDK generator for Node 18+
//! (docs/69 §13, D207).
//!
//! Writes `runtime.ts` (the static protocol runtime, with a JSON parser that
//! keeps number text so Long and ULong values above 2^53 are read exactly as
//! bigints) and `<package>.ts`: the boundary types, encoders and decoders per
//! D207 Decision 4, an interface, dispatcher and manifest helper per plugin
//! point, and a `<Capability>Client` and manifest helper per capability.  No
//! dependencies; ES modules.
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str

func tsKeywords(): List[String] {
  val k: List[String] = newList()
  for w in Str.split("break case catch class const continue debugger default delete do else enum export extends false finally for function if import in instanceof new null return super switch this throw true try typeof var void while with yield let static implements interface package private protected public await arguments eval", " ") {
    k.add(w)
  }
  k
}

func tsIdent(name: in String): String = if listContains(tsKeywords(), name) { name + "_" } else { name }

/// The module file name of a Lyric package: `Demo.Api` is `demo-api.ts`.
pub func tsModuleName(pkg: in String): String = Str.toLower(Str.replace(pkg, ".", "-"))

func tsType(t: in BType): String {
  match t {
    case BBool -> "boolean"
    case BByte -> "number"
    case BInt -> "number"
    case BUInt -> "number"
    case BLong -> "bigint"
    case BULong -> "bigint"
    case BFloat -> "number"
    case BDouble -> "number"
    case BChar -> "string"
    case BString -> "string"
    case BUnit -> "Unit"
    case BJson -> "JsonValue"
    case BBytes -> "Uint8Array"
    case BOption(i) -> match i { case BJson -> "JsonValue"; case _ -> tsType(i) + " | null" }
    case BResult(o, e) -> "Result<" + tsType(o) + ", " + tsType(e) + ">"
    case BList(e) -> "Array<" + tsType(e) + ">"
    case BMap(v) -> "Map<string, " + tsType(v) + ">"
    case BTuple(items) -> {
      val parts: List[String] = newList()
      for x in items {
        parts.add(tsType(x))
      }
      "[" + Str.joinList(", ", parts) + "]"
    }
    case BNamed(n) -> n
  }
}

func tsEnc(reg: in Registry, t: in BType, e: in String): String {
  val s = csScalarName(t)
  if s.length > 0 {
    return "Wire.encode" + s + "(" + e + ")"
  }
  match t {
    case BNamed(n) -> "encode" + n + "(" + e + ")"
    case _ -> "encode" + registerCompound(reg, t) + "(" + e + ")"
  }
}

func tsDec(reg: in Registry, t: in BType, j: in String, p: in String): String {
  val s = csScalarName(t)
  if s.length > 0 {
    return "Wire.decode" + s + "(" + j + ", " + p + ")"
  }
  match t {
    case BNamed(n) -> "decode" + n + "(" + j + ", " + p + ")"
    case _ -> "decode" + registerCompound(reg, t) + "(" + j + ", " + p + ")"
  }
}

func tsDefault(m: in ApiModel, t: in BType, d: in BDefault): String {
  match t {
    case BOption(inner) -> match d { case DefNone -> "null"; case _ -> tsDefault(m, inner, d) }
    case _ -> match d {
      case DefInt(v) -> match t {
        case BLong -> v.toString() + "n"
        case BULong -> v.toString() + "n"
        case _ -> v.toString()
      }
      case DefFloat(text) -> text
      case DefString(s) -> quoteString(s)
      case DefBool(b) -> if b { "true" } else { "false" }
      case DefNone -> "null"
      case DefEmptyList -> match t { case BBytes -> "new Uint8Array(0)"; case _ -> "[]" }
      case DefEmptyMap -> "new Map()"
      case DefEnum(typeName, caseName) -> match findDecl(m, typeName) {
        case Some(decl) -> match decl.kind {
          case KUnion(_) -> "{ case: " +
            quoteString(caseName) +
            " }"
          case _ -> quoteString(caseName)
        }
        case None -> quoteString(caseName)
      }
    }
  }
}

func tsDoc(o: in Out, indent: in String, doc: in String): Unit {
  if doc.length == 0 {
    return
  }
  emit(o, indent + "/**")
  for line in Str.split(doc, "\n") {
    emit(o, indent + " * " + Str.replace(line, "*/", "*\\/"))
  }
  emit(o, indent + " */")
}

func tsParams(params: in List[BParam]): String {
  val parts: List[String] = newList()
  for p in params {
    parts.add(tsIdent(p.name) + ": " + tsType(p.ty))
  }
  Str.joinList(", ", parts)
}

/// A property access, quoting a name that is not an identifier.
func tsMember(base: in String, name: in String): String = base + "." + name

// ── Types ────────────────────────────────────────────────────────────────────
func tsEmitDecl(m: in ApiModel, o: in Out, d: in BDecl): Unit {
  tsDoc(o, "", d.doc)
  match d.kind {
    case KRecord(fields) -> {
      emit(o, "export interface " + d.name + " {")
      for f in fields {
        val isOpt = match f.dflt { case Some(_) -> true; case None -> fieldIsOptional(f) }
        val mark = if isOpt { "?" } else { "" }
        emit(o, "  " + f.name + mark + ": " + tsType(f.ty) + ";")
      }
      emit(o, "}")
    }
    case KUnion(cases) -> {
      emit(o, "export type " + d.name + " =")
      var i = 0
      while i < cases.count {
        val c = cases[i]
        val parts: List[String] = newList()
        parts.add("case: " + quoteString(c.name))
        for f in c.fields {
          parts.add(f.name + ": " + tsType(f.ty))
        }
        val tail = if i + 1 < cases.count { "" } else { ";" }
        emit(o, "  | { " + Str.joinList("; ", parts) + " }" + tail)
        i = i + 1
      }
    }
    case KEnum(cases) -> {
      val names: List[String] = newList()
      for c in cases {
        names.add(quoteString(c))
      }
      emit(o, "export type " + d.name + " = " + Str.joinList(" | ", names) + ";")
      emit(o, "export const " + d.name + "Cases: readonly " + d.name + "[] = [" + Str.joinList(", ", names) + "];")
    }
    case KHandle -> {
      emit(o, "/** A plugin handle: an opaque token the host issues; it cannot be read or forged. */")
      emit(o, "export type " + d.name + " = bigint & { readonly __handle: " + quoteString(d.pkg + "." + d.name) + " };")
      emit(o, "export function " + d.name + "(value: bigint): " + d.name + " {")
      emit(o, "  return value as " + d.name + ";")
      emit(o, "}")
    }
  }
  emit(o, "")
}

// ── Codecs ───────────────────────────────────────────────────────────────────
func tsEmitDeclCodec(m: in ApiModel, reg: in Registry, o: in Out, d: in BDecl): Unit {
  match d.kind {
    case KRecord(fields) -> {
      emit(o, "export function encode" + d.name + "(v: " + d.name + "): JsonValue {")
      emit(o, "  if (v === null || v === undefined) throw new PluginProtocolError(\"a " + d.name + " must not be null\");")
      emit(o, "  return obj(")
      for f in fields {
        val access = tsMember("v", f.name)
        val value = match f.dflt {
          case Some(df) -> "(" + access + " === undefined ? " + tsDefault(m, f.ty, df) + " : " + access + ")"
          case None -> {
            if fieldIsOptional(f) {
              "(" + access + " ?? null)"
            } else {
              access
            }
          }
        }
        emit(o, "    [" + quoteString(f.name) + ", " + tsEnc(reg, f.ty, value) + "],")
      }
      emit(o, "  );")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + d.name + "(j: JsonValue | undefined, path: string): " + d.name + " {")
      emit(o, "  const o = Wire.expectObject(j, path);")
      emit(o, "  return {")
      for f in fields {
        val key = quoteString(f.name)
        val sub = "path + " + quoteString("." + f.name)
        val present = tsDec(reg, f.ty, "o.get(" + key + ")", sub)
        match f.dflt {
          case Some(df) -> emit(
            o,
            "    " + f.name + ": o.has(" + key + ") ? " + present + " : " + tsDefault(m, f.ty, df) + ","
          )
          case None -> {
            if fieldIsOptional(f) {
              emit(o, "    " + f.name + ": o.has(" + key + ") ? " + present + " : null,")
            } else {
              emit(o, "    " + f.name + ": " + tsDec(reg, f.ty, "Wire.required(o, " + key + ", path)", sub) + ",")
            }
          }
        }
      }
      emit(o, "  };")
      emit(o, "}")
    }
    case KUnion(cases) -> {
      emit(o, "export function encode" + d.name + "(v: " + d.name + "): JsonValue {")
      emit(o, "  if (v === null || v === undefined) throw new PluginProtocolError(\"a " + d.name + " must not be null\");")
      emit(o, "  switch (v.case) {")
      for c in cases {
        val members: List[String] = newList()
        members.add("[\"case\", " + quoteString(c.name) + "]")
        for f in c.fields {
          members.add("[" + quoteString(f.name) + ", " + tsEnc(reg, f.ty, tsMember("v", f.name)) + "]")
        }
        emit(o, "    case " + quoteString(c.name) + ":")
        emit(o, "      return obj(" + Str.joinList(", ", members) + ");")
      }
      emit(o, "    default:")
      emit(o, "      throw new PluginProtocolError(\"a " + d.name + " must be one of its cases\");")
      emit(o, "  }")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + d.name + "(j: JsonValue | undefined, path: string): " + d.name + " {")
      emit(o, "  const o = Wire.expectObject(j, path);")
      emit(o, "  const name = Wire.caseName(o, path);")
      emit(o, "  switch (name) {")
      for c in cases {
        val members: List[String] = newList()
        members.add("case: " + quoteString(c.name))
        for f in c.fields {
          members.add(
            f.name + ": " +
              tsDec(reg, f.ty, "Wire.required(o, " + quoteString(f.name) + ", path)", "path + " + quoteString("." + f.name))
          )
        }
        emit(o, "    case " + quoteString(c.name) + ":")
        emit(o, "      return { " + Str.joinList(", ", members) + " };")
      }
      emit(o, "    default:")
      emit(o, "      throw Wire.unknownCase(path, " + quoteString(d.name) + ", name);")
      emit(o, "  }")
      emit(o, "}")
    }
    case KEnum(_) -> {
      emit(o, "export function encode" + d.name + "(v: " + d.name + "): JsonValue {")
      emit(
        o,
        "  if (!" + d.name + "Cases.includes(v)) throw new PluginProtocolError(\"not a " + d.name +
          " case: \" + String(v));"
      )
      emit(o, "  return v;")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + d.name + "(j: JsonValue | undefined, path: string): " + d.name + " {")
      emit(o, "  const name = Wire.decodeString(j, path);")
      emit(
        o,
        "  if (!(" + d.name + "Cases as readonly string[]).includes(name)) throw Wire.unknownCase(path, " +
          quoteString(d.name) +
          ", name);"
      )
      emit(o, "  return name as " + d.name + ";")
      emit(o, "}")
    }
    case KHandle -> {
      emit(o, "export function encode" + d.name + "(v: " + d.name + "): JsonValue {")
      emit(o, "  return Wire.encodeLong(v);")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + d.name + "(j: JsonValue | undefined, path: string): " + d.name + " {")
      emit(o, "  return " + d.name + "(Wire.decodeLong(j, path));")
      emit(o, "}")
    }
  }
  emit(o, "")
}

func tsEmitCompoundCodec(m: in ApiModel, reg: in Registry, o: in Out, idx: in Int): Unit {
  val t = reg.types[idx]
  val n = reg.names[idx]
  val ty = tsType(t)
  match t {
    case BOption(inner) -> {
      emit(o, "export function encode" + n + "(v: " + ty + "): JsonValue {")
      emit(o, "  return v === null || v === undefined ? null : " + tsEnc(reg, inner, "v") + ";")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + n + "(j: JsonValue | undefined, path: string): " + ty + " {")
      emit(o, "  return j === null || j === undefined ? null : " + tsDec(reg, inner, "j", "path") + ";")
      emit(o, "}")
    }
    case BResult(okT, errT) -> {
      emit(o, "export function encode" + n + "(v: " + ty + "): JsonValue {")
      emit(
        o,
        "  if (v !== null && typeof v === \"object\" && \"ok\" in v) return obj([\"ok\", " + tsEnc(reg, okT, "v.ok") + "]);"
      )
      emit(
        o,
        "  if (v !== null && typeof v === \"object\" && \"err\" in v) return obj([\"err\", " + tsEnc(reg, errT, "v.err") +
          "]);"
      )
      emit(o, "  throw new PluginProtocolError(\"a Result must be {ok} or {err}\");")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + n + "(j: JsonValue | undefined, path: string): " + ty + " {")
      emit(o, "  const o = Wire.expectObject(j, path);")
      emit(
        o,
        "  if (o.size === 1 && o.has(\"ok\")) return { ok: " + tsDec(reg, okT, "o.get(\"ok\")", "path + \".ok\"") + " };"
      )
      emit(
        o,
        "  if (o.size === 1 && o.has(\"err\")) return { err: " + tsDec(reg, errT, "o.get(\"err\")", "path + \".err\"") +
          " };"
      )
      emit(o, "  throw new PluginProtocolError(path + ': expected {\"ok\": ...} or {\"err\": ...}');")
      emit(o, "}")
    }
    case BList(e) -> {
      emit(o, "export function encode" + n + "(v: " + ty + "): JsonValue {")
      emit(o, "  if (!Array.isArray(v)) throw new PluginProtocolError(\"expected an array\");")
      emit(o, "  return v.map((x) => " + tsEnc(reg, e, "x") + ");")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + n + "(j: JsonValue | undefined, path: string): " + ty + " {")
      emit(o, "  return Wire.expectArray(j, path).map((x, i) => " + tsDec(reg, e, "x", "path + \"[\" + i + \"]\"") + ");")
      emit(o, "}")
    }
    case BMap(v) -> {
      emit(o, "export function encode" + n + "(v: " + ty + "): JsonValue {")
      emit(o, "  if (!(v instanceof Map)) throw new PluginProtocolError(\"expected a Map\");")
      emit(o, "  const o: JsonObject = new Map();")
      emit(o, "  for (const [k, x] of v) o.set(k, " + tsEnc(reg, v, "x") + ");")
      emit(o, "  return o;")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + n + "(j: JsonValue | undefined, path: string): " + ty + " {")
      emit(o, "  const r: " + ty + " = new Map();")
      emit(
        o,
        "  for (const [k, x] of Wire.expectObject(j, path)) r.set(k, " + tsDec(reg, v, "x", "path + \".\" + k") + ");"
      )
      emit(o, "  return r;")
      emit(o, "}")
    }
    case BTuple(items) -> {
      val encs: List[String] = newList()
      val decs: List[String] = newList()
      var i = 0
      while i < items.count {
        encs.add(tsEnc(reg, items[i], "v[" + i.toString() + "]"))
        decs.add(tsDec(reg, items[i], "a[" + i.toString() + "]", "path + \"[" + i.toString() + "]\""))
        i = i + 1
      }
      emit(o, "export function encode" + n + "(v: " + ty + "): JsonValue {")
      emit(o, "  return [" + Str.joinList(", ", encs) + "];")
      emit(o, "}")
      emit(o, "")
      emit(o, "export function decode" + n + "(j: JsonValue | undefined, path: string): " + ty + " {")
      emit(o, "  const a = Wire.expectTuple(j, path, " + items.count.toString() + ");")
      emit(o, "  return [" + Str.joinList(", ", decs) + "];")
      emit(o, "}")
    }
    case _ -> ()
  }
  emit(o, "")
}

// ── Points and capabilities ──────────────────────────────────────────────────
func tsEmitPoint(m: in ApiModel, reg: in Registry, o: in Out, p: in BPoint): Unit {
  val id = pointId(p)
  if p.protocol.length > 0 {
    tsDoc(o, "", p.doc)
    emit(o, "/** A protocol point (" + p.protocol + "): the plugin speaks that protocol on stdin and stdout itself. */")
    emit(o, "export const " + p.name + "Point = {")
    emit(o, "  id: " + quoteString(id) + ",")
    emit(o, "  protocol: " + quoteString(p.protocol) + ",")
    emit(o, "} as const;")
    emit(o, "")
    return
  }
  tsDoc(o, "", p.doc)
  emit(o, "export interface " + p.name + " {")
  for mt in p.methods {
    tsDoc(o, "  ", mt.doc)
    val rt = tsType(BResult(ok = mt.ok, err = mt.err))
    emit(o, "  " + mt.name + "(" + tsParams(mt.params) + "): " + rt + " | Promise<" + rt + ">;")
  }
  emit(o, "}")
  emit(o, "")
  val names: List[String] = newList()
  for mt in p.methods {
    names.add(quoteString(mt.name))
  }
  emit(o, "/** Plugin point " + id + ", version " + p.version + ". */")
  emit(o, "export const " + p.name + "Point = {")
  emit(o, "  id: " + quoteString(id) + ",")
  emit(o, "  version: " + quoteString(p.version) + ",")
  emit(o, "  methods: [" + Str.joinList(", ", names) + "] as readonly string[],")
  emit(o, "  /** The dispatcher that routes this point's calls to `impl`. */")
  emit(o, "  dispatcher(impl: " + p.name + "): PointDispatcher {")
  emit(o, "    return new " + p.name + "Dispatcher(impl);")
  emit(o, "  },")
  if p.contributions.length > 0 {
    emit(o, "  /** Declares that the plugin implements this point, with its contributions. */")
    emit(o, "  implement(manifest: ManifestBuilder, contributions: " + p.contributions + "): ManifestBuilder {")
    emit(
      o,
      "    return manifest.point(" + p.name + "Point.id, " + p.name + "Point.version, encode" + p.contributions +
        "(contributions));"
    )
  } else {
    emit(o, "  /** Declares that the plugin implements this point. */")
    emit(o, "  implement(manifest: ManifestBuilder): ManifestBuilder {")
    emit(o, "    return manifest.point(" + p.name + "Point.id, " + p.name + "Point.version, null);")
  }
  emit(o, "  },")
  emit(o, "};")
  emit(o, "")
  emit(o, "class " + p.name + "Dispatcher implements PointDispatcher {")
  emit(o, "  readonly pointId = " + p.name + "Point.id;")
  emit(o, "  readonly version = " + p.name + "Point.version;")
  emit(o, "  readonly methods = " + p.name + "Point.methods;")
  emit(o, "")
  emit(o, "  constructor(private readonly impl: " + p.name + ") {}")
  emit(o, "")
  emit(o, "  async dispatch(method: string, ps: JsonObject): Promise<JsonValue> {")
  emit(o, "    switch (method) {")
  for mt in p.methods {
    emit(o, "      case " + quoteString(mt.name) + ": {")
    val args: List[String] = newList()
    for prm in mt.params {
      val local = "a_" + prm.name
      emit(
        o,
        "        const " + local + " = " +
          tsDec(
            reg,
            prm.ty,
            "Wire.required(ps, " + quoteString(prm.name) + ", \"params\")",
            quoteString("params." + prm.name)
          ) +
          ";"
      )
      args.add(local)
    }
    emit(o, "        const r = await this.impl." + mt.name + "(" + Str.joinList(", ", args) + ");")
    emit(o, "        return " + tsEnc(reg, BResult(ok = mt.ok, err = mt.err), "r") + ";")
    emit(o, "      }")
  }
  emit(o, "      default:")
  emit(
    o,
    "        throw new RpcError(Codes.Unsupported, " + quoteString(id + " has no method ") +
      " + method, obj([\"method\", " +
      quoteString(id + "/") +
      " + method]));"
  )
  emit(o, "    }")
  emit(o, "  }")
  emit(o, "}")
  emit(o, "")
}

func tsEmitCapability(m: in ApiModel, reg: in Registry, o: in Out, c: in BCapability): Unit {
  val id = capabilityId(c)
  tsDoc(o, "", c.doc)
  emit(o, "/** Calls capability " + id + " on the host. Every call is checked by the host. */")
  emit(o, "export class " + c.name + "Client {")
  emit(o, "  static readonly id = " + quoteString(id) + ";")
  emit(o, "")
  emit(o, "  constructor(private readonly context: PluginContext) {}")
  emit(o, "")
  emit(o, "  /** True when the host granted this capability. */")
  emit(o, "  get isGranted(): boolean {")
  emit(o, "    return this.context.isGranted(" + c.name + "Client.id);")
  emit(o, "  }")
  if c.grant.length > 0 {
    emit(o, "")
    emit(o, "  /** The grant the host gave, or null when the capability was not granted. */")
    emit(o, "  get grant(): " + c.grant + " | null {")
    emit(
      o,
      "    return this.isGranted ? decode" + c.grant + "(this.context.grantOf(" + c.name +
        "Client.id), \"grant\") : null;"
    )
    emit(o, "  }")
  }
  for mt in c.methods {
    emit(o, "")
    tsDoc(o, "  ", mt.doc)
    val members: List[String] = newList()
    for prm in mt.params {
      members.add("[" + quoteString(prm.name) + ", " + tsEnc(reg, prm.ty, tsIdent(prm.name)) + "]")
    }
    emit(
      o,
      "  " + mt.name + "(" + tsParams(mt.params) + "): Promise<Result<" + tsType(mt.ok) + ", CallError<" + tsType(mt.err) +
        ">>> {"
    )
    emit(o, "    return this.context.call(")
    emit(o, "      " + c.name + "Client.id,")
    emit(o, "      " + quoteString(mt.name) + ",")
    emit(o, "      obj(" + Str.joinList(", ", members) + "),")
    emit(o, "      (__j, __p) => " + tsDec(reg, mt.ok, "__j", "__p") + ",")
    emit(o, "      (__j, __p) => " + tsDec(reg, mt.err, "__j", "__p") + ",")
    emit(o, "    );")
    emit(o, "  }")
  }
  emit(o, "}")
  emit(o, "")
  emit(o, "/** Manifest helpers for capability " + id + ". */")
  emit(o, "export const " + c.name + "Capability = {")
  if c.grant.length > 0 {
    emit(o, "  /** Requests the capability; the plugin does not load without it. */")
    emit(o, "  require(manifest: ManifestBuilder, request: " + c.grant + "): ManifestBuilder {")
    emit(o, "    return manifest.require(" + c.name + "Client.id, encode" + c.grant + "(request));")
    emit(o, "  },")
    emit(o, "  /** Requests the capability; the plugin loads without it. */")
    emit(o, "  optional(manifest: ManifestBuilder, request: " + c.grant + "): ManifestBuilder {")
    emit(o, "    return manifest.optional(" + c.name + "Client.id, encode" + c.grant + "(request));")
    emit(o, "  },")
  } else {
    emit(o, "  /** Requests the capability; the plugin does not load without it. */")
    emit(o, "  require(manifest: ManifestBuilder): ManifestBuilder {")
    emit(o, "    return manifest.require(" + c.name + "Client.id, null);")
    emit(o, "  },")
    emit(o, "  /** Requests the capability; the plugin loads without it. */")
    emit(o, "  optional(manifest: ManifestBuilder): ManifestBuilder {")
    emit(o, "    return manifest.optional(" + c.name + "Client.id, null);")
    emit(o, "  },")
  }
  emit(o, "};")
  emit(o, "")
}

/// The TypeScript SDK for `m`.
pub func generateTypeScript(m: in ApiModel): SdkOutput {
  val errors: List[String] = newList()
  checkDefaults(m, errors)
  val reserved: List[String] = newList()
  for r in Str.split("Wire Result Unit JsonValue JsonObject JsonNumber BoundaryError CallError Codes ManifestBuilder PluginServer PluginContext PointDispatcher RpcError PluginProtocolError Map Array Promise Uint8Array Error Object String Number Boolean BigInt Symbol", " ") {
    reserved.add(r)
  }
  checkReservedNames(m, reserved, "TypeScript", errors)
  val reg = newRegistry(m)
  val types = newOut()
  for d in m.decls {
    tsEmitDecl(m, types, d)
  }
  val api = newOut()
  for p in m.points {
    tsEmitPoint(m, reg, api, p)
  }
  for c in m.capabilities {
    tsEmitCapability(m, reg, api, c)
  }
  val codec = newOut()
  for d in m.decls {
    tsEmitDeclCodec(m, reg, codec, d)
  }
  var done = 0
  while done < reg.types.count {
    tsEmitCompoundCodec(m, reg, codec, done)
    done = done + 1
  }
  val o = newOut()
  emit(
    o,
    "// Generated by `lyric plugin sdk` from the Lyric plugin API package " + m.packageName + " (D207). Do not edit."
  )
  emit(o, "/* eslint-disable */")
  emit(o, "import {")
  emit(o, "  type CallError,")
  emit(o, "  Codes,")
  emit(o, "  type JsonObject,")
  emit(o, "  type JsonValue,")
  emit(o, "  ManifestBuilder,")
  emit(o, "  obj,")
  emit(o, "  PluginContext,")
  emit(o, "  PluginProtocolError,")
  emit(o, "  type PointDispatcher,")
  emit(o, "  type Result,")
  emit(o, "  RpcError,")
  emit(o, "  type Unit,")
  emit(o, "  Wire,")
  emit(o, "} from \"./runtime.js\";")
  emit(o, "")
  for l in types.lines {
    emit(o, l)
  }
  for l in api.lines {
    emit(o, l)
  }
  emit(o, "// ── Encoders and decoders (D207 Decision 4) ──")
  emit(o, "")
  var trimmed = codec.lines.count
  while trimmed > 0 and codec.lines[trimmed - 1] == "" {
    trimmed = trimmed - 1
  }
  var li = 0
  while li < trimmed {
    emit(o, codec.lines[li])
    li = li + 1
  }
  val files: List[SdkFile] = newList()
  files.add(SdkFile(path = "runtime.ts", content = typescriptRuntimeSource()))
  files.add(SdkFile(path = tsModuleName(m.packageName) + ".ts", content = outText(o)))
  SdkOutput(files = files, errors = errors)
}
