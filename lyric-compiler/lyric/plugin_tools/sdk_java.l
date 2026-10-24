//! sdk_java.l - Lyric.PluginSdk: the Java 21 SDK generator (docs/69 §13, D207).
//!
//! Writes the static runtime (`lyric/plugin/*.java`: a JSON reader and writer,
//! the protocol server and the shared types) and, in the API's package
//! (`Demo.Api` becomes `demo.api`), one file per boundary type, a `Codec` of
//! encoders and decoders per D207 Decision 4, an interface and a `<Point>Point`
//! class per plugin point, and a `<Capability>Client` and `<Capability>Capability`
//! class per capability.  No dependencies beyond the JDK.
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str

func javaKeywords(): List[String] {
  val k: List[String] = newList()
  for w in Str.split("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var yield record sealed permits non-sealed when", " ") {
    k.add(w)
  }
  k
}

func jIdent(name: in String): String = if listContains(javaKeywords(), name) { name + "_" } else { name }

/// The Java package of a Lyric package: each segment lower-cased.
pub func javaPackageOf(pkg: in String): String {
  val parts: List[String] = newList()
  for seg in Str.split(pkg, ".") {
    parts.add(jIdent(Str.toLower(seg)))
  }
  Str.joinList(".", parts)
}

func jScalarName(t: in BType): String = csScalarName(t)

func jType(t: in BType, boxed: in Bool): String {
  match t {
    case BBool -> if boxed { "Boolean" } else { "boolean" }
    case BByte -> if boxed { "Integer" } else { "int" }
    case BInt -> if boxed { "Integer" } else { "int" }
    case BLong -> if boxed { "Long" } else { "long" }
    case BUInt -> if boxed { "Long" } else { "long" }
    case BULong -> if boxed { "Long" } else { "long" }
    case BFloat -> if boxed { "Float" } else { "float" }
    case BDouble -> if boxed { "Double" } else { "double" }
    case BChar -> if boxed { "Character" } else { "char" }
    case BString -> "String"
    case BUnit -> "Unit"
    case BJson -> "Json.Value"
    case BBytes -> "byte[]"
    case BOption(i) -> "java.util.Optional<" + jType(i, true) + ">"
    case BResult(o, e) -> "Result<" + jType(o, true) + ", " + jType(e, true) + ">"
    case BList(e) -> "java.util.List<" + jType(e, true) + ">"
    case BMap(v) -> "java.util.Map<String, " + jType(v, true) + ">"
    case BTuple(items) -> {
      val parts: List[String] = newList()
      for x in items {
        parts.add(jType(x, true))
      }
      "Tuple.Of" + items.count.toString() + "<" + Str.joinList(", ", parts) + ">"
    }
    case BNamed(n) -> n
  }
}

func jEnc(reg: in Registry, t: in BType, e: in String, prefix: in String): String {
  val s = jScalarName(t)
  if s.length > 0 {
    return "Wire.encode" + s + "(" + e + ")"
  }
  match t {
    case BNamed(n) -> prefix + "encode" + n + "(" + e + ")"
    case _ -> prefix + "encode" + registerCompound(reg, t) + "(" + e + ")"
  }
}

func jDec(reg: in Registry, t: in BType, j: in String, p: in String, prefix: in String): String {
  val s = jScalarName(t)
  if s.length > 0 {
    return "Wire.decode" + s + "(" + j + ", " + p + ")"
  }
  match t {
    case BNamed(n) -> prefix + "decode" + n + "(" + j + ", " + p + ")"
    case _ -> prefix + "decode" + registerCompound(reg, t) + "(" + j + ", " + p + ")"
  }
}

func jDefault(m: in ApiModel, t: in BType, d: in BDefault): String {
  match t {
    case BOption(inner) -> match d {
      case DefNone -> "java.util.Optional.empty()"
      case _ -> "java.util.Optional.of(" + jDefault(m, inner, d) + ")"
    }
    case _ -> match d {
      case DefInt(v) -> match t {
        case BLong -> v.toString() + "L"
        case BUInt -> v.toString() + "L"
        case BULong -> v.toString() + "L"
        case BFloat -> v.toString() + "f"
        case BDouble -> v.toString() + "d"
        case _ -> v.toString()
      }
      case DefFloat(text) -> match t { case BFloat -> text + "f"; case _ -> text + "d" }
      case DefString(s) -> match t { case BChar -> quoteString(s) + ".charAt(0)"; case _ -> quoteString(s) }
      case DefBool(b) -> if b { "true" } else { "false" }
      case DefNone -> "null"
      case DefEmptyList -> match t { case BBytes -> "new byte[0]"; case _ -> "new java.util.ArrayList<>()" }
      case DefEmptyMap -> "new java.util.LinkedHashMap<>()"
      case DefEnum(typeName, caseName) -> match findDecl(m, typeName) {
        case Some(decl) -> match decl.kind {
          case KUnion(_) -> "new " + typeName + "." +
            caseName +
            "()"
          case _ -> typeName + "." + jIdent(caseName)
        }
        case None -> typeName + "." + jIdent(caseName)
      }
    }
  }
}

func jDoc(o: in Out, indent: in String, doc: in String): Unit {
  if doc.length == 0 {
    return
  }
  emit(o, indent + "/**")
  for line in Str.split(doc, "\n") {
    emit(o, indent + " * " + Str.replace(line, "*/", "*&#47;"))
  }
  emit(o, indent + " */")
}

func jParams(params: in List[BParam]): String {
  val parts: List[String] = newList()
  for p in params {
    parts.add(jType(p.ty, false) + " " + jIdent(p.name))
  }
  Str.joinList(", ", parts)
}

func jHeader(m: in ApiModel, javaPkg: in String): Out {
  val o = newOut()
  emit(
    o,
    "// Generated by `lyric plugin sdk` from the Lyric plugin API package " + m.packageName + " (D207). Do not edit."
  )
  emit(o, "package " + javaPkg + ";")
  emit(o, "")
  emit(o, "import lyric.plugin.*;")
  emit(o, "")
  o
}

func jFile(files: in List[SdkFile], javaPkg: in String, name: in String, o: in Out): Unit {
  files.add(SdkFile(path = Str.replace(javaPkg, ".", "/") + "/" + name + ".java", content = outText(o)))
}

// ── Types ────────────────────────────────────────────────────────────────────
func jEmitDecl(m: in ApiModel, files: in List[SdkFile], javaPkg: in String, d: in BDecl, errors: in List[String]): Unit {
  val o = jHeader(m, javaPkg)
  jDoc(o, "", d.doc)
  match d.kind {
    case KRecord(fields) -> {
      val comps: List[String] = newList()
      for f in fields {
        comps.add(jType(f.ty, false) + " " + jIdent(f.name))
      }
      emit(o, "public record " + d.name + "(" + Str.joinList(", ", comps) + ") {}")
    }
    case KUnion(cases) -> {
      val names: List[String] = newList()
      for c in cases {
        if c.name == d.name {
          errors.add(
            "error: union case " + d.name + "." + c.name +
              " has its union's name, which Java does not allow for a nested type; rename it"
          )
        }
        names.add(d.name + "." + c.name)
      }
      emit(o, "public sealed interface " + d.name + " permits " + Str.joinList(", ", names) + " {")
      for c in cases {
        val comps: List[String] = newList()
        for f in c.fields {
          comps.add(jType(f.ty, false) + " " + jIdent(f.name))
        }
        emit(o, "    record " + c.name + "(" + Str.joinList(", ", comps) + ") implements " + d.name + " {}")
      }
      emit(o, "}")
    }
    case KEnum(cases) -> {
      val names: List[String] = newList()
      for c in cases {
        names.add(jIdent(c))
      }
      emit(o, "public enum " + d.name + " {")
      emit(o, "    " + Str.joinList(", ", names))
      emit(o, "}")
    }
    case KHandle -> {
      emit(o, "/** A plugin handle: an opaque token the host issues; it cannot be read or forged. */")
      emit(o, "public record " + d.name + "(long value) {}")
    }
  }
  jFile(files, javaPkg, d.name, o)
}

// ── Codec ────────────────────────────────────────────────────────────────────
func jEmitDeclCodec(m: in ApiModel, reg: in Registry, o: in Out, d: in BDecl): Unit {
  match d.kind {
    case KRecord(fields) -> {
      emit(o, "    public static Json.Value encode" + d.name + "(" + d.name + " v) {")
      emit(o, "        if (v == null) throw new ProtocolException(\"a " + d.name + " must not be null\");")
      emit(o, "        Json.Obj o = new Json.Obj();")
      for f in fields {
        emit(o, "        o.put(" + quoteString(f.name) + ", " + jEnc(reg, f.ty, "v." + jIdent(f.name) + "()", "") + ");")
      }
      emit(o, "        return o;")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + d.name + " decode" + d.name + "(Json.Value j, String path) {")
      emit(o, "        Json.Obj o = Wire.expectObject(j, path);")
      val args: List[String] = newList()
      for f in fields {
        val key = quoteString(f.name)
        val sub = "path + " + quoteString("." + f.name)
        val present = jDec(reg, f.ty, "o.get(" + key + ")", sub, "")
        match f.dflt {
          case Some(df) -> args.add("o.has(" + key + ") ? " + present + " : " + jDefault(m, f.ty, df))
          case None -> {
            if fieldIsOptional(f) {
              args.add("o.has(" + key + ") ? " + present + " : java.util.Optional.empty()")
            } else {
              args.add(jDec(reg, f.ty, "Wire.required(o, " + key + ", path)", sub, ""))
            }
          }
        }
      }
      if args.count == 0 {
        emit(o, "        return new " + d.name + "();")
      } else {
        emit(o, "        return new " + d.name + "(")
        var i = 0
        while i < args.count {
          val sep = if i + 1 < args.count { "," } else { ");" }
          emit(o, "            " + args[i] + sep)
          i = i + 1
        }
      }
      emit(o, "    }")
    }
    case KUnion(cases) -> {
      emit(o, "    public static Json.Value encode" + d.name + "(" + d.name + " v) {")
      for c in cases {
        emit(o, "        if (v instanceof " + d.name + "." + c.name + " c) {")
        emit(o, "            Json.Obj o = new Json.Obj().put(\"case\", Json.str(" + quoteString(c.name) + "));")
        for f in c.fields {
          emit(o, "            o.put(" + quoteString(f.name) + ", " + jEnc(reg, f.ty, "c." + jIdent(f.name) + "()", "") + ");")
        }
        emit(o, "            return o;")
        emit(o, "        }")
      }
      emit(o, "        throw new ProtocolException(\"a " + d.name + " must be one of its cases\");")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + d.name + " decode" + d.name + "(Json.Value j, String path) {")
      emit(o, "        Json.Obj o = Wire.expectObject(j, path);")
      emit(o, "        String name = Wire.caseName(o, path);")
      emit(o, "        switch (name) {")
      for c in cases {
        val args: List[String] = newList()
        for f in c.fields {
          args.add(
            jDec(reg, f.ty, "Wire.required(o, " + quoteString(f.name) + ", path)", "path + " + quoteString("." + f.name), "")
          )
        }
        emit(o, "            case " + quoteString(c.name) + ":")
        emit(o, "                return new " + d.name + "." + c.name + "(" + Str.joinList(", ", args) + ");")
      }
      emit(o, "            default:")
      emit(o, "                throw Wire.unknownCase(path, " + quoteString(d.name) + ", name);")
      emit(o, "        }")
      emit(o, "    }")
    }
    case KEnum(cases) -> {
      emit(o, "    public static Json.Value encode" + d.name + "(" + d.name + " v) {")
      emit(o, "        if (v == null) throw new ProtocolException(\"a " + d.name + " must not be null\");")
      emit(o, "        return switch (v) {")
      for c in cases {
        emit(o, "            case " + jIdent(c) + " -> Json.str(" + quoteString(c) + ");")
      }
      emit(o, "        };")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + d.name + " decode" + d.name + "(Json.Value j, String path) {")
      emit(o, "        String name = Wire.decodeString(j, path);")
      emit(o, "        switch (name) {")
      for c in cases {
        emit(o, "            case " + quoteString(c) + ": return " + d.name + "." + jIdent(c) + ";")
      }
      emit(o, "            default: throw Wire.unknownCase(path, " + quoteString(d.name) + ", name);")
      emit(o, "        }")
      emit(o, "    }")
    }
    case KHandle -> {
      emit(o, "    public static Json.Value encode" + d.name + "(" + d.name + " v) {")
      emit(o, "        return Wire.encodeLong(v.value());")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + d.name + " decode" + d.name + "(Json.Value j, String path) {")
      emit(o, "        return new " + d.name + "(Wire.decodeLong(j, path));")
      emit(o, "    }")
    }
  }
  emit(o, "")
}

func jEmitCompoundCodec(m: in ApiModel, reg: in Registry, o: in Out, idx: in Int, errors: in List[String]): Unit {
  val t = reg.types[idx]
  val n = reg.names[idx]
  val ty = jType(t, false)
  match t {
    case BOption(inner) -> {
      emit(o, "    public static Json.Value encode" + n + "(" + ty + " v) {")
      emit(o, "        return v.isPresent() ? " + jEnc(reg, inner, "v.get()", "") + " : Json.NULL;")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + ty + " decode" + n + "(Json.Value j, String path) {")
      emit(
        o,
        "        return j == null || j instanceof Json.Null ? java.util.Optional.empty() : java.util.Optional.of(" +
          jDec(reg, inner, "j", "path", "") +
          ");"
      )
      emit(o, "    }")
    }
    case BResult(okT, errT) -> {
      emit(o, "    public static Json.Value encode" + n + "(" + ty + " v) {")
      emit(
        o,
        "        if (v instanceof Result.Ok<" + jType(okT, true) + ", " + jType(errT, true) +
          "> ok) return new Json.Obj().put(\"ok\", " +
          jEnc(reg, okT, "ok.value()", "") +
          ");"
      )
      emit(
        o,
        "        if (v instanceof Result.Err<" + jType(okT, true) + ", " + jType(errT, true) +
          "> e) return new Json.Obj().put(\"err\", " +
          jEnc(reg, errT, "e.error()", "") +
          ");"
      )
      emit(o, "        throw new ProtocolException(\"a Result must be Ok or Err\");")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + ty + " decode" + n + "(Json.Value j, String path) {")
      emit(o, "        Json.Obj o = Wire.expectObject(j, path);")
      emit(
        o,
        "        if (o.members().size() == 1 && o.has(\"ok\")) return Result.ok(" +
          jDec(reg, okT, "o.get(\"ok\")", "path + \".ok\"", "") +
          ");"
      )
      emit(
        o,
        "        if (o.members().size() == 1 && o.has(\"err\")) return Result.err(" +
          jDec(reg, errT, "o.get(\"err\")", "path + \".err\"", "") +
          ");"
      )
      emit(o, "        throw new ProtocolException(path + \": expected {\\\"ok\\\": ...} or {\\\"err\\\": ...}\");")
      emit(o, "    }")
    }
    case BList(e) -> {
      emit(o, "    public static Json.Value encode" + n + "(" + ty + " v) {")
      emit(o, "        if (v == null) throw new ProtocolException(\"a list must not be null\");")
      emit(o, "        Json.Arr a = new Json.Arr();")
      emit(o, "        for (" + jType(e, true) + " x : v) a.items().add(" + jEnc(reg, e, "x", "") + ");")
      emit(o, "        return a;")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + ty + " decode" + n + "(Json.Value j, String path) {")
      emit(o, "        Json.Arr a = Wire.expectArray(j, path);")
      emit(o, "        " + ty + " r = new java.util.ArrayList<>(a.items().size());")
      emit(
        o,
        "        for (int i = 0; i < a.items().size(); i++) r.add(" +
          jDec(reg, e, "a.items().get(i)", "path + \"[\" + i + \"]\"", "") +
          ");"
      )
      emit(o, "        return r;")
      emit(o, "    }")
    }
    case BMap(v) -> {
      emit(o, "    public static Json.Value encode" + n + "(" + ty + " v) {")
      emit(o, "        if (v == null) throw new ProtocolException(\"a map must not be null\");")
      emit(o, "        Json.Obj o = new Json.Obj();")
      emit(
        o,
        "        for (java.util.Map.Entry<String, " + jType(v, true) + "> kv : v.entrySet()) o.put(kv.getKey(), " +
          jEnc(reg, v, "kv.getValue()", "") +
          ");"
      )
      emit(o, "        return o;")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + ty + " decode" + n + "(Json.Value j, String path) {")
      emit(o, "        Json.Obj o = Wire.expectObject(j, path);")
      emit(o, "        " + ty + " r = new java.util.LinkedHashMap<>();")
      emit(
        o,
        "        for (java.util.Map.Entry<String, Json.Value> kv : o.members().entrySet()) r.put(kv.getKey(), " +
          jDec(reg, v, "kv.getValue()", "path + \".\" + kv.getKey()", "") +
          ");"
      )
      emit(o, "        return r;")
      emit(o, "    }")
    }
    case BTuple(items) -> {
      if items.count > 8 {
        errors.add(
          "error: the Java SDK supports tuples of up to 8 elements; " + canonType(t) + " has " + items.count.toString()
        )
        return
      }
      emit(o, "    public static Json.Value encode" + n + "(" + ty + " v) {")
      emit(o, "        Json.Arr a = new Json.Arr();")
      val decs: List[String] = newList()
      var i = 0
      while i < items.count {
        emit(o, "        a.items().add(" + jEnc(reg, items[i], "v.item" + (i + 1).toString() + "()", "") + ");")
        decs.add(jDec(reg, items[i], "a.items().get(" + i.toString() + ")", "path + \"[" + i.toString() + "]\"", ""))
        i = i + 1
      }
      emit(o, "        return a;")
      emit(o, "    }")
      emit(o, "")
      emit(o, "    public static " + ty + " decode" + n + "(Json.Value j, String path) {")
      emit(o, "        Json.Arr a = Wire.expectTuple(j, path, " + items.count.toString() + ");")
      emit(o, "        return new Tuple.Of" + items.count.toString() + "<>(" + Str.joinList(", ", decs) + ");")
      emit(o, "    }")
    }
    case _ -> ()
  }
  emit(o, "")
}

// ── Points and capabilities ──────────────────────────────────────────────────
func jEmitPoint(m: in ApiModel, reg: in Registry, files: in List[SdkFile], javaPkg: in String, p: in BPoint): Unit {
  val id = pointId(p)
  if p.protocol.length > 0 {
    val o = jHeader(m, javaPkg)
    jDoc(o, "", p.doc)
    emit(o, "/** A protocol point (" + p.protocol + "): the plugin speaks that protocol on stdin and stdout itself. */")
    emit(o, "public final class " + p.name + "Point {")
    emit(o, "    private " + p.name + "Point() {}")
    emit(o, "")
    emit(o, "    public static final String ID = " + quoteString(id) + ";")
    emit(o, "    public static final String PROTOCOL = " + quoteString(p.protocol) + ";")
    emit(o, "}")
    jFile(files, javaPkg, p.name + "Point", o)
    return
  }
  val iface = jHeader(m, javaPkg)
  jDoc(iface, "", p.doc)
  emit(iface, "public interface " + p.name + " {")
  var first = true
  for mt in p.methods {
    if not first {
      emit(iface, "")
    }
    first = false
    jDoc(iface, "    ", mt.doc)
    emit(
      iface,
      "    " + jType(BResult(ok = mt.ok, err = mt.err), false) + " " + jIdent(mt.name) + "(" + jParams(mt.params) + ");"
    )
  }
  emit(iface, "}")
  jFile(files, javaPkg, p.name, iface)

  val o = jHeader(m, javaPkg)
  emit(o, "/** Plugin point " + id + ", version " + p.version + ". */")
  emit(o, "public final class " + p.name + "Point {")
  emit(o, "    private " + p.name + "Point() {}")
  emit(o, "")
  emit(o, "    public static final String ID = " + quoteString(id) + ";")
  emit(o, "    public static final String VERSION = " + quoteString(p.version) + ";")
  val names: List[String] = newList()
  for mt in p.methods {
    names.add(quoteString(mt.name))
  }
  emit(
    o,
    "    public static final java.util.List<String> METHODS = java.util.List.of(" + Str.joinList(", ", names) + ");"
  )
  emit(o, "")
  emit(o, "    /** The dispatcher that routes this point's calls to {@code impl}. */")
  emit(o, "    public static PointDispatcher dispatcher(" + p.name + " impl) {")
  emit(o, "        return new Dispatcher(java.util.Objects.requireNonNull(impl));")
  emit(o, "    }")
  emit(o, "")
  if p.contributions.length > 0 {
    emit(o, "    /** Declares that the plugin implements this point, with its contributions. */")
    emit(
      o,
      "    public static ManifestBuilder implement(ManifestBuilder manifest, " + p.contributions + " contributions) {"
    )
    emit(o, "        return manifest.point(ID, VERSION, Codec.encode" + p.contributions + "(contributions));")
  } else {
    emit(o, "    /** Declares that the plugin implements this point. */")
    emit(o, "    public static ManifestBuilder implement(ManifestBuilder manifest) {")
    emit(o, "        return manifest.point(ID, VERSION, Json.NULL);")
  }
  emit(o, "    }")
  emit(o, "")
  emit(o, "    private static final class Dispatcher implements PointDispatcher {")
  emit(o, "        private final " + p.name + " impl;")
  emit(o, "")
  emit(o, "        Dispatcher(" + p.name + " impl) {")
  emit(o, "            this.impl = impl;")
  emit(o, "        }")
  emit(o, "")
  emit(o, "        @Override public String pointId() { return ID; }")
  emit(o, "")
  emit(o, "        @Override public String version() { return VERSION; }")
  emit(o, "")
  emit(o, "        @Override public java.util.List<String> methods() { return METHODS; }")
  emit(o, "")
  emit(o, "        @Override")
  emit(o, "        public Json.Value dispatch(String method, Json.Obj ps) {")
  emit(o, "            switch (method) {")
  for mt in p.methods {
    emit(o, "                case " + quoteString(mt.name) + ": {")
    val args: List[String] = newList()
    for prm in mt.params {
      val local = "a_" + prm.name
      emit(
        o,
        "                    " + jType(prm.ty, false) + " " + local + " = " +
          jDec(
            reg,
            prm.ty,
            "Wire.required(ps, " + quoteString(prm.name) + ", \"params\")",
            quoteString("params." + prm.name),
            "Codec."
          ) +
          ";"
      )
      args.add(local)
    }
    val call = "impl." + jIdent(mt.name) + "(" + Str.joinList(", ", args) + ")"
    emit(o, "                    return " + jEnc(reg, BResult(ok = mt.ok, err = mt.err), call, "Codec.") + ";")
    emit(o, "                }")
  }
  emit(o, "                default:")
  emit(
    o,
    "                    throw new RpcException(Codes.UNSUPPORTED, " + quoteString(id + " has no method ") +
      " + method, new Json.Obj().put(\"method\", Json.str(ID + \"/\" + method)));"
  )
  emit(o, "            }")
  emit(o, "        }")
  emit(o, "    }")
  emit(o, "}")
  jFile(files, javaPkg, p.name + "Point", o)
}

func jEmitCapability(
  m: in ApiModel, reg: in Registry, files: in List[SdkFile], javaPkg: in String, c: in BCapability
): Unit {
  val id = capabilityId(c)
  val o = jHeader(m, javaPkg)
  jDoc(o, "", c.doc)
  emit(o, "/** Calls capability " + id + " on the host. Every call is checked by the host. */")
  emit(o, "public final class " + c.name + "Client {")
  emit(o, "    public static final String ID = " + quoteString(id) + ";")
  emit(o, "    private final PluginContext context;")
  emit(o, "")
  emit(o, "    public " + c.name + "Client(PluginContext context) {")
  emit(o, "        this.context = java.util.Objects.requireNonNull(context);")
  emit(o, "    }")
  emit(o, "")
  emit(o, "    /** True when the host granted this capability. */")
  emit(o, "    public boolean isGranted() {")
  emit(o, "        return context.isGranted(ID);")
  emit(o, "    }")
  if c.grant.length > 0 {
    emit(o, "")
    emit(o, "    /** The grant the host gave, or empty when the capability was not granted. */")
    emit(o, "    public java.util.Optional<" + c.grant + "> grant() {")
    emit(
      o,
      "        return context.isGranted(ID) ? java.util.Optional.of(Codec.decode" + c.grant +
        "(context.grantOf(ID), \"grant\")) : java.util.Optional.empty();"
    )
    emit(o, "    }")
  }
  for mt in c.methods {
    emit(o, "")
    jDoc(o, "    ", mt.doc)
    emit(
      o,
      "    public Result<" + jType(mt.ok, true) + ", CallError<" + jType(mt.err, true) + ">> " + jIdent(mt.name) + "(" +
        jParams(mt.params) +
        ") {"
    )
    emit(o, "        Json.Obj ps__ = new Json.Obj();")
    for prm in mt.params {
      emit(o, "        ps__.put(" + quoteString(prm.name) + ", " + jEnc(reg, prm.ty, jIdent(prm.name), "Codec.") + ");")
    }
    emit(
      o,
      "        return context.call(ID, " + quoteString(mt.name) + ", ps__, (j__, p__) -> " +
        jDec(reg, mt.ok, "j__", "p__", "Codec.") +
        ", (j__, p__) -> " +
        jDec(reg, mt.err, "j__", "p__", "Codec.") +
        ");"
    )
    emit(o, "    }")
  }
  emit(o, "}")
  jFile(files, javaPkg, c.name + "Client", o)

  val h = jHeader(m, javaPkg)
  emit(h, "/** Manifest helpers for capability " + id + ". */")
  emit(h, "public final class " + c.name + "Capability {")
  emit(h, "    private " + c.name + "Capability() {}")
  emit(h, "")
  if c.grant.length > 0 {
    emit(h, "    /** Requests the capability; the plugin does not load without it. */")
    emit(h, "    public static ManifestBuilder require(ManifestBuilder manifest, " + c.grant + " request) {")
    emit(h, "        return manifest.require(" + c.name + "Client.ID, Codec.encode" + c.grant + "(request));")
    emit(h, "    }")
    emit(h, "")
    emit(h, "    /** Requests the capability; the plugin loads without it. */")
    emit(h, "    public static ManifestBuilder optional(ManifestBuilder manifest, " + c.grant + " request) {")
    emit(h, "        return manifest.optional(" + c.name + "Client.ID, Codec.encode" + c.grant + "(request));")
    emit(h, "    }")
  } else {
    emit(h, "    /** Requests the capability; the plugin does not load without it. */")
    emit(h, "    public static ManifestBuilder require(ManifestBuilder manifest) {")
    emit(h, "        return manifest.require(" + c.name + "Client.ID, Json.NULL);")
    emit(h, "    }")
    emit(h, "")
    emit(h, "    /** Requests the capability; the plugin loads without it. */")
    emit(h, "    public static ManifestBuilder optional(ManifestBuilder manifest) {")
    emit(h, "        return manifest.optional(" + c.name + "Client.ID, Json.NULL);")
    emit(h, "    }")
  }
  emit(h, "}")
  jFile(files, javaPkg, c.name + "Capability", h)
}

/// The Java SDK for `m`.
pub func generateJava(m: in ApiModel): SdkOutput {
  val errors: List[String] = newList()
  checkDefaults(m, errors)
  val reserved: List[String] = newList()
  for r in Str.split("Codec Wire Json Result Unit Tuple BoundaryError CallError Codes ManifestBuilder PluginServer PluginContext PointDispatcher RpcException ProtocolException String Object Integer Long Double Float Boolean Character Byte Short Math System Thread Override", " ") {
    reserved.add(r)
  }
  checkReservedNames(m, reserved, "Java", errors)
  val javaPkg = javaPackageOf(m.packageName)
  val files: List[SdkFile] = newList()
  for name in javaRuntimeFileNames() {
    files.add(SdkFile(path = "lyric/plugin/" + name, content = javaRuntimeFile(name)))
  }
  val reg = newRegistry(m)
  for d in m.decls {
    jEmitDecl(m, files, javaPkg, d, errors)
  }
  for p in m.points {
    jEmitPoint(m, reg, files, javaPkg, p)
  }
  for c in m.capabilities {
    jEmitCapability(m, reg, files, javaPkg, c)
  }
  val body = newOut()
  for d in m.decls {
    jEmitDeclCodec(m, reg, body, d)
  }
  var done = 0
  while done < reg.types.count {
    jEmitCompoundCodec(m, reg, body, done, errors)
    done = done + 1
  }
  val o = jHeader(m, javaPkg)
  emit(o, "/** Encoders and decoders of this API's boundary types (D207 Decision 4). */")
  emit(o, "public final class Codec {")
  emit(o, "    private Codec() {}")
  emit(o, "")
  var trimmed = body.lines.count
  while trimmed > 0 and body.lines[trimmed - 1] == "" {
    trimmed = trimmed - 1
  }
  var li = 0
  while li < trimmed {
    emit(o, body.lines[li])
    li = li + 1
  }
  emit(o, "}")
  jFile(files, javaPkg, "Codec", o)
  SdkOutput(files = files, errors = errors)
}
