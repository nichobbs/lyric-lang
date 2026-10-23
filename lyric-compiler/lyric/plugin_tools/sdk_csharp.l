//! sdk_csharp.l - Lyric.PluginSdk: the C# SDK generator (docs/69 §13, D207).
//!
//! Writes `LyricPluginRuntime.cs` (the static protocol runtime) and
//! `<Package>.Plugin.cs`: the boundary types, a `Codec` of encoders and
//! decoders per D207 Decision 4, an `I<Point>` interface, dispatcher and
//! manifest helper per plugin point, and a `<Capability>Client` and manifest
//! helper per capability.  Plain .NET with System.Text.Json; no NuGet
//! dependencies.
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str

func csKeywords(): List[String] {
  val k: List[String] = newList()
  for w in Str.split("abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while", " ") {
    k.add(w)
  }
  k
}

func csIdent(name: in String): String = if listContains(csKeywords(), name) { "@" + name } else { name }

func csProp(name: in String): String = csIdent(upperFirst(name))

func csScalarName(t: in BType): String {
  match t {
    case BBool -> "Bool"
    case BByte -> "Byte"
    case BInt -> "Int"
    case BLong -> "Long"
    case BUInt -> "UInt"
    case BULong -> "ULong"
    case BFloat -> "Float"
    case BDouble -> "Double"
    case BChar -> "Char"
    case BString -> "String"
    case BUnit -> "Unit"
    case BJson -> "Json"
    case BBytes -> "Bytes"
    case _ -> ""
  }
}

func csType(t: in BType): String {
  match t {
    case BBool -> "bool"
    case BByte -> "byte"
    case BInt -> "int"
    case BLong -> "long"
    case BUInt -> "uint"
    case BULong -> "ulong"
    case BFloat -> "float"
    case BDouble -> "double"
    case BChar -> "char"
    case BString -> "string"
    case BUnit -> "Unit"
    case BJson -> "JsonNode?"
    case BBytes -> "byte[]"
    case BOption(i) -> match i { case BJson -> "JsonNode?"; case _ -> csType(i) + "?" }
    case BResult(o, e) -> "Result<" + csType(o) + ", " + csType(e) + ">"
    case BList(e) -> "List<" + csType(e) + ">"
    case BMap(v) -> "Dictionary<string, " + csType(v) + ">"
    case BTuple(items) -> {
      val parts: List[String] = newList()
      for x in items {
        parts.add(csType(x))
      }
      "(" + Str.joinList(", ", parts) + ")"
    }
    case BNamed(n) -> n
  }
}

/// True when the C# type of `t` is a value type (so `T?` is `Nullable<T>`).
func csIsValueType(m: in ApiModel, t: in BType): Bool {
  match t {
    case BBool -> true
    case BByte -> true
    case BInt -> true
    case BLong -> true
    case BUInt -> true
    case BULong -> true
    case BFloat -> true
    case BDouble -> true
    case BChar -> true
    case BUnit -> true
    case BTuple(_) -> true
    case BNamed(n) -> match findDecl(m, n) {
      case Some(d) -> match d.kind { case KEnum(_) -> true; case KHandle -> true; case _ -> false }
      case None -> false
    }
    case _ -> false
  }
}

func csEnc(reg: in Registry, t: in BType, e: in String, prefix: in String): String {
  val s = csScalarName(t)
  if s.length > 0 {
    return "Wire.Encode" + s + "(" + e + ")"
  }
  match t {
    case BNamed(n) -> prefix + "Encode" + n + "(" + e + ")"
    case _ -> prefix + "Encode" + registerCompound(reg, t) + "(" + e + ")"
  }
}

func csDec(reg: in Registry, t: in BType, j: in String, p: in String, prefix: in String): String {
  val s = csScalarName(t)
  if s.length > 0 {
    return "Wire.Decode" + s + "(" + j + ", " + p + ")"
  }
  match t {
    case BNamed(n) -> prefix + "Decode" + n + "(" + j + ", " + p + ")"
    case _ -> prefix + "Decode" + registerCompound(reg, t) + "(" + j + ", " + p + ")"
  }
}

func csDefault(m: in ApiModel, t: in BType, d: in BDefault): String {
  match t {
    case BOption(inner) -> match d { case DefNone -> "null"; case _ -> csDefault(m, inner, d) }
    case _ -> match d {
      case DefInt(v) -> match t {
        case BByte -> "(byte)" + v.toString()
        case BLong -> v.toString() + "L"
        case BUInt -> v.toString() + "U"
        case BULong -> v.toString() + "UL"
        case BFloat -> v.toString() + "F"
        case BDouble -> v.toString() + "D"
        case _ -> v.toString()
      }
      case DefFloat(text) -> match t { case BFloat -> text + "F"; case _ -> text + "D" }
      case DefString(s) -> match t { case BChar -> quoteString(s) + "[0]"; case _ -> quoteString(s) }
      case DefBool(b) -> if b { "true" } else { "false" }
      case DefNone -> "null"
      case DefEmptyList -> match t {
        case BBytes -> "Array.Empty<byte>()"
        case _ -> "new " + csType(t) + "()"
      }
      case DefEmptyMap -> "new " + csType(t) + "()"
      case DefEnum(typeName, caseName) -> match findDecl(m, typeName) {
        case Some(decl) -> match decl.kind {
          case KUnion(_) -> "new " + typeName + "." +
            caseName +
            "()"
          case _ -> typeName + "." + caseName
        }
        case None -> typeName + "." + caseName
      }
    }
  }
}

func xmlEscape(s: in String): String = Str.replace(Str.replace(Str.replace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

func csDoc(o: in Out, indent: in String, doc: in String): Unit {
  if doc.length == 0 {
    return
  }
  emit(o, indent + "/// <summary>")
  for line in Str.split(doc, "\n") {
    emit(o, indent + "/// " + xmlEscape(line))
  }
  emit(o, indent + "/// </summary>")
}

func csParams(params: in List[BParam]): String {
  val parts: List[String] = newList()
  for p in params {
    parts.add(csType(p.ty) + " " + csIdent(p.name))
  }
  Str.joinList(", ", parts)
}

// ── Types ────────────────────────────────────────────────────────────────────
func csEmitDecl(m: in ApiModel, o: in Out, d: in BDecl, errors: in List[String]): Unit {
  csDoc(o, "    ", d.doc)
  match d.kind {
    case KRecord(fields) -> {
      emit(o, "    public sealed class " + d.name)
      emit(o, "    {")
      for f in fields {
        if upperFirst(f.name) == d.name {
          errors.add("error: field " + d.name + "." + f.name + " would be a C# property named like its class; rename it")
        }
        val ty = csType(f.ty)
        match f.dflt {
          case Some(df) -> emit(
            o,
            "        public " + ty + " " + csProp(f.name) + " { get; init; } = " + csDefault(m, f.ty, df) +
              ";"
          )
          case None -> {
            if fieldIsOptional(f) {
              emit(o, "        public " + ty + " " + csProp(f.name) + " { get; init; }")
            } else {
              emit(o, "        public required " + ty + " " + csProp(f.name) + " { get; init; }")
            }
          }
        }
      }
      emit(o, "    }")
    }
    case KUnion(cases) -> {
      emit(o, "    public abstract record " + d.name)
      emit(o, "    {")
      emit(o, "        private " + d.name + "() { }")
      for c in cases {
        if c.name == d.name {
          errors.add(
            "error: union case " + d.name + "." + c.name +
              " has its union's name, which C# does not allow for a nested type; rename it"
          )
        }
        val ps: List[String] = newList()
        for f in c.fields {
          if upperFirst(f.name) == c.name {
            errors.add(
              "error: field " + f.name + " of union case " + d.name + "." + c.name +
                " would be a C# property named like its case; rename it"
            )
          }
          ps.add(csType(f.ty) + " " + csProp(f.name))
        }
        emit(o, "")
        emit(o, "        public sealed record " + c.name + "(" + Str.joinList(", ", ps) + ") : " + d.name + ";")
      }
      emit(o, "    }")
    }
    case KEnum(cases) -> {
      emit(o, "    public enum " + d.name)
      emit(o, "    {")
      for c in cases {
        emit(o, "        " + csIdent(c) + ",")
      }
      emit(o, "    }")
    }
    case KHandle -> {
      emit(o, "    /// <remarks>A plugin handle: an opaque token the host issues; it cannot be read or forged.</remarks>")
      emit(o, "    public readonly record struct " + d.name + "(long Value);")
    }
  }
  emit(o, "")
}

// ── Codec ────────────────────────────────────────────────────────────────────
func csEmitDeclCodec(m: in ApiModel, reg: in Registry, o: in Out, d: in BDecl): Unit {
  match d.kind {
    case KRecord(fields) -> {
      emit(o, "        public static JsonNode Encode" + d.name + "(" + d.name + " v)")
      emit(o, "        {")
      emit(o, "            if (v is null) throw new PluginProtocolException(\"a " + d.name + " must not be null\");")
      emit(o, "            var o = new JsonObject();")
      for f in fields {
        emit(o, "            o[" + quoteString(f.name) + "] = " + csEnc(reg, f.ty, "v." + csProp(f.name), "") + ";")
      }
      emit(o, "            return o;")
      emit(o, "        }")
      emit(o, "")
      emit(o, "        public static " + d.name + " Decode" + d.name + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var o = Wire.ExpectObject(j, path);")
      emit(o, "            return new " + d.name)
      emit(o, "            {")
      for f in fields {
        val key = quoteString(f.name)
        val sub = "path + " + quoteString("." + f.name)
        val present = csDec(reg, f.ty, "o[" + key + "]", sub, "")
        match f.dflt {
          case Some(df) -> emit(
            o,
            "                " + csProp(f.name) + " = Wire.Has(o, " + key + ") ? " + present + " : " +
              csDefault(m, f.ty, df) +
              ","
          )
          case None -> {
            if fieldIsOptional(f) {
              emit(o, "                " + csProp(f.name) + " = Wire.Has(o, " + key + ") ? " + present + " : null,")
            } else {
              emit(
                o,
                "                " + csProp(f.name) + " = " + csDec(reg, f.ty, "Wire.Required(o, " + key + ", path)", sub, "") + ","
              )
            }
          }
        }
      }
      emit(o, "            };")
      emit(o, "        }")
    }
    case KUnion(cases) -> {
      emit(o, "        public static JsonNode Encode" + d.name + "(" + d.name + " v)")
      emit(o, "        {")
      emit(o, "            switch (v)")
      emit(o, "            {")
      for c in cases {
        emit(o, "                case " + d.name + "." + c.name + " c:")
        emit(o, "                {")
        emit(o, "                    var o = new JsonObject();")
        emit(o, "                    o[\"case\"] = " + quoteString(c.name) + ";")
        for f in c.fields {
          emit(o, "                    o[" + quoteString(f.name) + "] = " + csEnc(reg, f.ty, "c." + csProp(f.name), "") + ";")
        }
        emit(o, "                    return o;")
        emit(o, "                }")
      }
      emit(o, "                default:")
      emit(o, "                    throw new PluginProtocolException(\"a " + d.name + " must be one of its cases\");")
      emit(o, "            }")
      emit(o, "        }")
      emit(o, "")
      emit(o, "        public static " + d.name + " Decode" + d.name + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var o = Wire.ExpectObject(j, path);")
      emit(o, "            var name = Wire.CaseName(o, path);")
      emit(o, "            switch (name)")
      emit(o, "            {")
      for c in cases {
        val args: List[String] = newList()
        for f in c.fields {
          args.add(
            csDec(reg, f.ty, "Wire.Required(o, " + quoteString(f.name) + ", path)", "path + " + quoteString("." + f.name), "")
          )
        }
        emit(o, "                case " + quoteString(c.name) + ":")
        emit(o, "                    return new " + d.name + "." + c.name + "(" + Str.joinList(", ", args) + ");")
      }
      emit(o, "                default:")
      emit(o, "                    throw Wire.UnknownCase(path, " + quoteString(d.name) + ", name);")
      emit(o, "            }")
      emit(o, "        }")
    }
    case KEnum(cases) -> {
      emit(o, "        public static JsonNode Encode" + d.name + "(" + d.name + " v) => v switch")
      emit(o, "        {")
      for c in cases {
        emit(o, "            " + d.name + "." + csIdent(c) + " => JsonValue.Create(" + quoteString(c) + "),")
      }
      emit(o, "            _ => throw new PluginProtocolException(\"not a " + d.name + " case: \" + v),")
      emit(o, "        };")
      emit(o, "")
      emit(o, "        public static " + d.name + " Decode" + d.name + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var name = Wire.DecodeString(j, path);")
      emit(o, "            switch (name)")
      emit(o, "            {")
      for c in cases {
        emit(o, "                case " + quoteString(c) + ": return " + d.name + "." + csIdent(c) + ";")
      }
      emit(o, "                default: throw Wire.UnknownCase(path, " + quoteString(d.name) + ", name);")
      emit(o, "            }")
      emit(o, "        }")
    }
    case KHandle -> {
      emit(o, "        public static JsonNode Encode" + d.name + "(" + d.name + " v) => Wire.EncodeLong(v.Value);")
      emit(o, "")
      emit(
        o,
        "        public static " + d.name + " Decode" + d.name + "(JsonNode? j, string path) => new " + d.name +
          "(Wire.DecodeLong(j, path));"
      )
    }
  }
  emit(o, "")
}

func csEmitCompoundCodec(m: in ApiModel, reg: in Registry, o: in Out, idx: in Int): Unit {
  val t = reg.types[idx]
  val n = reg.names[idx]
  val ty = csType(t)
  match t {
    case BOption(inner) -> {
      if csIsValueType(m, inner) {
        emit(
          o,
          "        public static JsonNode? Encode" + n + "(" + ty + " v) => v.HasValue ? " + csEnc(reg, inner, "v.Value", "") +
            " : null;"
        )
      } else {
        emit(
          o,
          "        public static JsonNode? Encode" + n + "(" + ty + " v) => v is null ? null : " + csEnc(reg, inner, "v", "") +
            ";"
        )
      }
      emit(o, "")
      emit(
        o,
        "        public static " + ty + " Decode" + n + "(JsonNode? j, string path) => j is null ? null : " +
          csDec(reg, inner, "j", "path", "") +
          ";"
      )
    }
    case BResult(okT, errT) -> {
      emit(o, "        public static JsonNode Encode" + n + "(" + ty + " v) => v switch")
      emit(o, "        {")
      emit(o, "            " + ty + ".Ok ok => new JsonObject { [\"ok\"] = " + csEnc(reg, okT, "ok.Value", "") + " },")
      emit(o, "            " + ty + ".Err e => new JsonObject { [\"err\"] = " + csEnc(reg, errT, "e.Error", "") + " },")
      emit(o, "            _ => throw new PluginProtocolException(\"a Result must be Ok or Err\"),")
      emit(o, "        };")
      emit(o, "")
      emit(o, "        public static " + ty + " Decode" + n + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var o = Wire.ExpectObject(j, path);")
      emit(o, "            if (o.Count == 1 && o.TryGetPropertyValue(\"ok\", out var okNode))")
      emit(o, "                return " + ty + ".Success(" + csDec(reg, okT, "okNode", "path + \".ok\"", "") + ");")
      emit(o, "            if (o.Count == 1 && o.TryGetPropertyValue(\"err\", out var errNode))")
      emit(o, "                return " + ty + ".Failure(" + csDec(reg, errT, "errNode", "path + \".err\"", "") + ");")
      emit(
        o,
        "            throw new PluginProtocolException(path + \": expected {\\\"ok\\\": ...} or {\\\"err\\\": ...}\");"
      )
      emit(o, "        }")
    }
    case BList(e) -> {
      emit(o, "        public static JsonNode Encode" + n + "(" + ty + " v)")
      emit(o, "        {")
      emit(o, "            if (v is null) throw new PluginProtocolException(\"a list must not be null\");")
      emit(o, "            var a = new JsonArray();")
      emit(o, "            foreach (var x in v) a.Add(" + csEnc(reg, e, "x", "") + ");")
      emit(o, "            return a;")
      emit(o, "        }")
      emit(o, "")
      emit(o, "        public static " + ty + " Decode" + n + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var a = Wire.ExpectArray(j, path);")
      emit(o, "            var r = new " + ty + "(a.Count);")
      emit(
        o,
        "            for (var i = 0; i < a.Count; i++) r.Add(" + csDec(reg, e, "a[i]", "path + \"[\" + i + \"]\"", "") +
          ");"
      )
      emit(o, "            return r;")
      emit(o, "        }")
    }
    case BMap(v) -> {
      emit(o, "        public static JsonNode Encode" + n + "(" + ty + " v)")
      emit(o, "        {")
      emit(o, "            if (v is null) throw new PluginProtocolException(\"a map must not be null\");")
      emit(o, "            var o = new JsonObject();")
      emit(o, "            foreach (var kv in v) o[kv.Key] = " + csEnc(reg, v, "kv.Value", "") + ";")
      emit(o, "            return o;")
      emit(o, "        }")
      emit(o, "")
      emit(o, "        public static " + ty + " Decode" + n + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var o = Wire.ExpectObject(j, path);")
      emit(o, "            var r = new " + ty + "();")
      emit(
        o,
        "            foreach (var kv in o) r[kv.Key] = " + csDec(reg, v, "kv.Value", "path + \".\" + kv.Key", "") + ";"
      )
      emit(o, "            return r;")
      emit(o, "        }")
    }
    case BTuple(items) -> {
      val encs: List[String] = newList()
      val decs: List[String] = newList()
      var i = 0
      while i < items.count {
        encs.add(csEnc(reg, items[i], "v.Item" + (i + 1).toString(), ""))
        decs.add(csDec(reg, items[i], "a[" + i.toString() + "]", "path + \"[" + i.toString() + "]\"", ""))
        i = i + 1
      }
      emit(
        o,
        "        public static JsonNode Encode" + n + "(" + ty + " v) => new JsonArray(" + Str.joinList(", ", encs) + ");"
      )
      emit(o, "")
      emit(o, "        public static " + ty + " Decode" + n + "(JsonNode? j, string path)")
      emit(o, "        {")
      emit(o, "            var a = Wire.ExpectTuple(j, path, " + items.count.toString() + ");")
      emit(o, "            return (" + Str.joinList(", ", decs) + ");")
      emit(o, "        }")
    }
    case _ -> ()
  }
  emit(o, "")
}

// ── Points and capabilities ──────────────────────────────────────────────────
func csMethodNames(methods: in List[BMethod]): String {
  val parts: List[String] = newList()
  for mt in methods {
    parts.add(quoteString(mt.name))
  }
  Str.joinList(", ", parts)
}

func csEmitPoint(m: in ApiModel, reg: in Registry, o: in Out, p: in BPoint): Unit {
  val id = pointId(p)
  if p.protocol.length > 0 {
    csDoc(o, "    ", p.doc)
    emit(
      o,
      "    /// <remarks>A protocol point (" + xmlEscape(p.protocol) +
        "): the plugin speaks that protocol on stdin and stdout itself.</remarks>"
    )
    emit(o, "    public static class " + p.name + "Point")
    emit(o, "    {")
    emit(o, "        public const string Id = " + quoteString(id) + ";")
    emit(o, "        public const string Protocol = " + quoteString(p.protocol) + ";")
    emit(o, "    }")
    emit(o, "")
    return
  }
  csDoc(o, "    ", p.doc)
  emit(o, "    public interface I" + p.name)
  emit(o, "    {")
  for mt in p.methods {
    csDoc(o, "        ", mt.doc)
    emit(
      o,
      "        " + csType(BResult(ok = mt.ok, err = mt.err)) + " " + upperFirst(mt.name) + "(" + csParams(mt.params) +
        ");"
    )
  }
  emit(o, "    }")
  emit(o, "")
  emit(o, "    /// <summary>Plugin point " + id + ", version " + p.version + ".</summary>")
  emit(o, "    public static class " + p.name + "Point")
  emit(o, "    {")
  emit(o, "        public const string Id = " + quoteString(id) + ";")
  emit(o, "        public const string Version = " + quoteString(p.version) + ";")
  emit(o, "        public static readonly IReadOnlyList<string> Methods = new[] { " + csMethodNames(p.methods) + " };")
  emit(o, "")
  emit(o, "        /// <summary>The dispatcher that routes this point's calls to <paramref name=\"impl\"/>.</summary>")
  emit(
    o,
    "        public static IPointDispatcher Dispatcher(I" + p.name + " impl) => new " + p.name + "Dispatcher(impl);"
  )
  emit(o, "")
  if p.contributions.length > 0 {
    emit(o, "        /// <summary>Declares that the plugin implements this point, with its contributions.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Implement" + p.name + "(this ManifestBuilder manifest, " + p.contributions +
        " contributions) =>"
    )
    emit(o, "            manifest.Point(Id, Version, Codec.Encode" + p.contributions + "(contributions));")
  } else {
    emit(o, "        /// <summary>Declares that the plugin implements this point.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Implement" + p.name +
        "(this ManifestBuilder manifest) => manifest.Point(Id, Version, null);"
    )
  }
  emit(o, "    }")
  emit(o, "")
  emit(o, "    internal sealed class " + p.name + "Dispatcher : IPointDispatcher")
  emit(o, "    {")
  emit(o, "        private readonly I" + p.name + " impl;")
  emit(o, "")
  emit(
    o,
    "        public " + p.name + "Dispatcher(I" + p.name +
      " impl) { this.impl = impl ?? throw new ArgumentNullException(nameof(impl)); }"
  )
  emit(o, "")
  emit(o, "        public string PointId => " + p.name + "Point.Id;")
  emit(o, "        public string Version => " + p.name + "Point.Version;")
  emit(o, "        public IReadOnlyList<string> Methods => " + p.name + "Point.Methods;")
  emit(o, "")
  emit(o, "        public JsonNode Dispatch(string method, JsonObject? parameters)")
  emit(o, "        {")
  emit(o, "            var ps = parameters ?? new JsonObject();")
  emit(o, "            switch (method)")
  emit(o, "            {")
  for mt in p.methods {
    emit(o, "                case " + quoteString(mt.name) + ":")
    emit(o, "                {")
    val args: List[String] = newList()
    for prm in mt.params {
      val local = "a_" + prm.name
      emit(
        o,
        "                    var " + local + " = " +
          csDec(
            reg,
            prm.ty,
            "Wire.Required(ps, " + quoteString(prm.name) + ", \"params\")",
            quoteString("params." + prm.name),
            "Codec."
          ) +
          ";"
      )
      args.add(local)
    }
    val call = "impl." + upperFirst(mt.name) + "(" + Str.joinList(", ", args) + ")"
    emit(o, "                    return " + csEnc(reg, BResult(ok = mt.ok, err = mt.err), call, "Codec.") + ";")
    emit(o, "                }")
  }
  emit(o, "                default:")
  emit(
    o,
    "                    throw new RpcException(Codes.Unsupported, " + quoteString(id + " has no method ") +
      " + method, new JsonObject { [\"method\"] = " +
      quoteString(id + "/") +
      " + method });"
  )
  emit(o, "            }")
  emit(o, "        }")
  emit(o, "    }")
  emit(o, "")
}

func csEmitCapability(m: in ApiModel, reg: in Registry, o: in Out, c: in BCapability): Unit {
  val id = capabilityId(c)
  csDoc(o, "    ", c.doc)
  emit(o, "    /// <remarks>Calls capability " + id + " on the host. Every call is checked by the host.</remarks>")
  emit(o, "    public sealed class " + c.name + "Client")
  emit(o, "    {")
  emit(o, "        public const string Id = " + quoteString(id) + ";")
  emit(o, "        private readonly PluginContext context;")
  emit(o, "")
  emit(
    o,
    "        public " + c.name +
      "Client(PluginContext context) { this.context = context ?? throw new ArgumentNullException(nameof(context)); }"
  )
  emit(o, "")
  emit(o, "        /// <summary>True when the host granted this capability.</summary>")
  emit(o, "        public bool IsGranted => context.IsGranted(Id);")
  if c.grant.length > 0 {
    emit(o, "")
    emit(o, "        /// <summary>The grant the host gave, or null when the capability was not granted.</summary>")
    emit(
      o,
      "        public " + c.grant + "? Grant => context.IsGranted(Id) ? Codec.Decode" + c.grant +
        "(context.GrantOf(Id), \"grant\") : null;"
    )
  }
  for mt in c.methods {
    emit(o, "")
    csDoc(o, "        ", mt.doc)
    emit(
      o,
      "        public Result<" + csType(mt.ok) + ", CallError<" + csType(mt.err) + ">> " + upperFirst(mt.name) + "(" +
        csParams(mt.params) +
        ")"
    )
    emit(o, "        {")
    emit(o, "            var __ps = new JsonObject();")
    for prm in mt.params {
      emit(o, "            __ps[" + quoteString(prm.name) + "] = " + csEnc(reg, prm.ty, csIdent(prm.name), "Codec.") + ";")
    }
    emit(
      o,
      "            return context.Call(Id, " + quoteString(mt.name) + ", __ps, (__j, __p) => " +
        csDec(reg, mt.ok, "__j", "__p", "Codec.") +
        ", (__j, __p) => " +
        csDec(reg, mt.err, "__j", "__p", "Codec.") +
        ");"
    )
    emit(o, "        }")
  }
  emit(o, "    }")
  emit(o, "")
  emit(o, "    /// <summary>Manifest helpers for capability " + id + ".</summary>")
  emit(o, "    public static class " + c.name + "Capability")
  emit(o, "    {")
  if c.grant.length > 0 {
    emit(o, "        /// <summary>Requests the capability; the plugin does not load without it.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Require" + c.name + "(this ManifestBuilder manifest, " + c.grant +
        " request) =>"
    )
    emit(o, "            manifest.Require(" + c.name + "Client.Id, Codec.Encode" + c.grant + "(request));")
    emit(o, "")
    emit(o, "        /// <summary>Requests the capability; the plugin loads without it.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Optional" + c.name + "(this ManifestBuilder manifest, " + c.grant +
        " request) =>"
    )
    emit(o, "            manifest.Optional(" + c.name + "Client.Id, Codec.Encode" + c.grant + "(request));")
  } else {
    emit(o, "        /// <summary>Requests the capability; the plugin does not load without it.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Require" + c.name + "(this ManifestBuilder manifest) => manifest.Require(" +
        c.name +
        "Client.Id, null);"
    )
    emit(o, "")
    emit(o, "        /// <summary>Requests the capability; the plugin loads without it.</summary>")
    emit(
      o,
      "        public static ManifestBuilder Optional" + c.name + "(this ManifestBuilder manifest) => manifest.Optional(" +
        c.name +
        "Client.Id, null);"
    )
  }
  emit(o, "    }")
  emit(o, "")
}

/// The C# SDK for `m`.
pub func generateCSharp(m: in ApiModel): SdkOutput {
  val errors: List[String] = newList()
  checkDefaults(m, errors)
  val reserved: List[String] = newList()
  for r in Str.split("Codec Wire Result Unit BoundaryError CallError Codes ManifestBuilder PluginServer PluginContext PluginConnection IPointDispatcher RpcException PluginProtocolException", " ") {
    reserved.add(r)
  }
  checkReservedNames(m, reserved, "C#", errors)
  val reg = newRegistry(m)
  val types = newOut()
  for d in m.decls {
    csEmitDecl(m, types, d, errors)
  }
  val api = newOut()
  for p in m.points {
    csEmitPoint(m, reg, api, p)
  }
  for c in m.capabilities {
    csEmitCapability(m, reg, api, c)
  }
  val codec = newOut()
  for d in m.decls {
    csEmitDeclCodec(m, reg, codec, d)
  }
  var done = 0
  while done < reg.types.count {
    csEmitCompoundCodec(m, reg, codec, done)
    done = done + 1
  }
  val o = newOut()
  emit(
    o,
    "// Generated by `lyric plugin sdk` from the Lyric plugin API package " + m.packageName + " (D207). Do not edit."
  )
  emit(o, "#nullable enable")
  emit(o, "using System;")
  emit(o, "using System.Collections.Generic;")
  emit(o, "using System.Text.Json.Nodes;")
  emit(o, "using Lyric.Plugin;")
  emit(o, "")
  emit(o, "namespace " + m.packageName)
  emit(o, "{")
  for l in types.lines {
    emit(o, l)
  }
  for l in api.lines {
    emit(o, l)
  }
  emit(o, "    /// <summary>Encoders and decoders of this API's boundary types (D207 Decision 4).</summary>")
  emit(o, "    public static class Codec")
  emit(o, "    {")
  var trimmed = codec.lines.count
  while trimmed > 0 and codec.lines[trimmed - 1] == "" {
    trimmed = trimmed - 1
  }
  var li = 0
  while li < trimmed {
    emit(o, codec.lines[li])
    li = li + 1
  }
  emit(o, "    }")
  emit(o, "}")
  val files: List[SdkFile] = newList()
  files.add(SdkFile(path = "LyricPluginRuntime.cs", content = csharpRuntimeSource()))
  files.add(SdkFile(path = m.packageName + ".Plugin.cs", content = outText(o)))
  SdkOutput(files = files, errors = errors)
}
