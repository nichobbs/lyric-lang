//! sdk_schema.l - Lyric.PluginSdk: the JSON Schema of a plugin API (docs/69 §13).
//!
//! A JSON Schema 2020-12 document whose `$defs` describe every boundary type in
//! its D207 Decision 4 encoding, with the points and capabilities, their wire
//! method names and each method's params and result schemas under
//! `x-lyric-points` and `x-lyric-capabilities`.  A plugin in a language without
//! a generated SDK can be written against it.
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str
import Std.JsonValue

func sf(name: in String, value: in JsonValue): JsonField = JsonField(name = name, value = value)

func sobj(fields: in List[JsonField]): JsonValue = JObject(fields = fields)

func sstr(s: in String): JsonValue = JString(value = s)

func one(name: in String, value: in JsonValue): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(sf(name, value))
  sobj(fs)
}

func two(n1: in String, v1: in JsonValue, n2: in String, v2: in JsonValue): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(sf(n1, v1))
  fs.add(sf(n2, v2))
  sobj(fs)
}

// ULong's maximum is outside the JSON value model's i64 integers, so it is
// written as this marker string and replaced by the exact number afterwards.
val ulongMaxMarker: String = "\"__lyric_ulong_max__\""

func integerSchema(min: in Long, max: in JsonValue): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(sf("type", sstr("integer")))
  fs.add(sf("minimum", JInt(value = min)))
  fs.add(sf("maximum", max))
  sobj(fs)
}

func defRef(name: in String): JsonValue = one("$ref", sstr("#/$defs/" + name))

func schemaOf(t: in BType): JsonValue {
  match t {
    case BBool -> one("type", sstr("boolean"))
    case BByte -> integerSchema(0i64, JInt(value = 255i64))
    case BInt -> integerSchema(-2147483648i64, JInt(value = 2147483647i64))
    case BLong -> integerSchema(-9223372036854775807i64 - 1i64, JInt(value = 9223372036854775807i64))
    case BUInt -> integerSchema(0i64, JInt(value = 4294967295i64))
    case BULong -> integerSchema(0i64, JString(value = "__lyric_ulong_max__"))
    case BFloat -> one("type", sstr("number"))
    case BDouble -> one("type", sstr("number"))
    case BChar -> {
      val fs: List[JsonField] = newList()
      fs.add(sf("type", sstr("string")))
      fs.add(sf("minLength", JInt(value = 1)))
      fs.add(sf("maxLength", JInt(value = 1)))
      sobj(fs)
    }
    case BString -> one("type", sstr("string"))
    case BUnit -> one("type", sstr("null"))
    case BJson -> JBool(value = true)
    case BBytes -> two("type", sstr("string"), "contentEncoding", sstr("base64"))
    case BOption(inner) -> {
      val alts: List[JsonValue] = newList()
      alts.add(one("type", sstr("null")))
      alts.add(schemaOf(inner))
      one("anyOf", JArray(items = alts))
    }
    case BResult(o, e) -> {
      val alts: List[JsonValue] = newList()
      alts.add(resultArm("ok", schemaOf(o)))
      alts.add(resultArm("err", schemaOf(e)))
      one("oneOf", JArray(items = alts))
    }
    case BList(e) -> two("type", sstr("array"), "items", schemaOf(e))
    case BMap(v) -> two("type", sstr("object"), "additionalProperties", schemaOf(v))
    case BTuple(items) -> {
      val prefix: List[JsonValue] = newList()
      for x in items {
        prefix.add(schemaOf(x))
      }
      val fs: List[JsonField] = newList()
      fs.add(sf("type", sstr("array")))
      fs.add(sf("prefixItems", JArray(items = prefix)))
      fs.add(sf("items", JBool(value = false)))
      fs.add(sf("minItems", JInt(value = items.count.toLong())))
      sobj(fs)
    }
    case BNamed(n) -> defRef(n)
  }
}

func resultArm(name: in String, s: in JsonValue): JsonValue {
  val required: List[JsonValue] = newList()
  required.add(sstr(name))
  val fs: List[JsonField] = newList()
  fs.add(sf("type", sstr("object")))
  fs.add(sf("properties", one(name, s)))
  fs.add(sf("required", JArray(items = required)))
  fs.add(sf("additionalProperties", JBool(value = false)))
  sobj(fs)
}

func objectSchema(fields: in List[BField], caseName: in String): JsonValue {
  val props: List[JsonField] = newList()
  val required: List[JsonValue] = newList()
  if caseName.length > 0 {
    props.add(sf("case", one("const", sstr(caseName))))
    required.add(sstr("case"))
  }
  for f in fields {
    props.add(sf(f.name, schemaOf(f.ty)))
    if not fieldIsOptional(f) {
      required.add(sstr(f.name))
    }
  }
  val fs: List[JsonField] = newList()
  fs.add(sf("type", sstr("object")))
  fs.add(sf("properties", sobj(props)))
  fs.add(sf("required", JArray(items = required)))
  sobj(fs)
}

func declSchema(d: in BDecl): JsonValue {
  val fs: List[JsonField] = newList()
  if d.doc.length > 0 {
    fs.add(sf("description", sstr(d.doc)))
  }
  match d.kind {
    case KRecord(fields) -> {
      match objectSchema(fields, "") {
        case JObject(more) -> {
          for x in more {
            fs.add(x)
          }
        }
        case _ -> ()
      }
    }
    case KUnion(cases) -> {
      val alts: List[JsonValue] = newList()
      for c in cases {
        alts.add(objectSchema(c.fields, c.name))
      }
      fs.add(sf("oneOf", JArray(items = alts)))
    }
    case KEnum(cases) -> {
      val names: List[JsonValue] = newList()
      for c in cases {
        names.add(sstr(c))
      }
      fs.add(sf("enum", JArray(items = names)))
    }
    case KHandle -> {
      fs.add(sf("type", sstr("integer")))
      fs.add(sf("x-lyric-handle", JBool(value = true)))
    }
  }
  sobj(fs)
}

func methodSchema(wire: in String, mt: in BMethod): JsonValue {
  val props: List[JsonField] = newList()
  val required: List[JsonValue] = newList()
  for p in mt.params {
    props.add(sf(p.name, schemaOf(p.ty)))
    required.add(sstr(p.name))
  }
  val params: List[JsonField] = newList()
  params.add(sf("type", sstr("object")))
  params.add(sf("properties", sobj(props)))
  params.add(sf("required", JArray(items = required)))
  val fs: List[JsonField] = newList()
  fs.add(sf("name", sstr(mt.name)))
  fs.add(sf("method", sstr(wire)))
  if mt.doc.length > 0 {
    fs.add(sf("description", sstr(mt.doc)))
  }
  fs.add(sf("params", sobj(params)))
  fs.add(sf("result", schemaOf(BResult(ok = mt.ok, err = mt.err))))
  sobj(fs)
}

func idList(ids: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for s in ids {
    items.add(sstr(s))
  }
  JArray(items = items)
}

/// The JSON Schema document of `m`, as indented JSON text.
pub func generateSchema(m: in ApiModel): String {
  val defs: List[JsonField] = newList()
  for d in m.decls {
    defs.add(sf(d.name, declSchema(d)))
  }
  val points: List[JsonValue] = newList()
  for p in m.points {
    val fs: List[JsonField] = newList()
    fs.add(sf("id", sstr(pointId(p))))
    if p.protocol.length > 0 {
      fs.add(sf("protocol", sstr(p.protocol)))
    } else {
      fs.add(sf("version", sstr(p.version)))
    }
    if p.doc.length > 0 {
      fs.add(sf("description", sstr(p.doc)))
    }
    fs.add(sf("contributions", if p.contributions.length > 0 { defRef(p.contributions) } else { JNull }))
    fs.add(sf("allows", idList(p.allows)))
    val methods: List[JsonValue] = newList()
    for mt in p.methods {
      methods.add(methodSchema(pointId(p) + "/" + mt.name, mt))
    }
    fs.add(sf("methods", JArray(items = methods)))
    points.add(sobj(fs))
  }
  val caps: List[JsonValue] = newList()
  for c in m.capabilities {
    val fs: List[JsonField] = newList()
    fs.add(sf("id", sstr(capabilityId(c))))
    if c.doc.length > 0 {
      fs.add(sf("description", sstr(c.doc)))
    }
    fs.add(sf("grant", if c.grant.length > 0 { defRef(c.grant) } else { JNull }))
    val methods: List[JsonValue] = newList()
    for mt in c.methods {
      methods.add(methodSchema("cap/" + capabilityId(c) + "/" + mt.name, mt))
    }
    fs.add(sf("methods", JArray(items = methods)))
    caps.add(sobj(fs))
  }
  val top: List[JsonField] = newList()
  top.add(sf("$schema", sstr("https://json-schema.org/draft/2020-12/schema")))
  top.add(sf("$id", sstr("urn:lyric-plugin-api:" + m.packageName)))
  top.add(sf("title", sstr(m.packageName + " plugin boundary")))
  top.add(
    sf(
      "description",
      sstr(
        "The boundary types and methods of the Lyric plugin API package " + m.packageName +
          ", in the D207 wire encoding (JSON-RPC 2.0, protocol 1). Generated by `lyric plugin sdk`."
      )
    )
  )
  top.add(sf("x-lyric-protocol", JInt(value = 1)))
  top.add(sf("$defs", sobj(defs)))
  top.add(sf("x-lyric-points", JArray(items = points)))
  top.add(sf("x-lyric-capabilities", JArray(items = caps)))
  Str.replace(writeValueIndented(sobj(top), 2), ulongMaxMarker, "18446744073709551615") + "\n"
}

/// The SDK for `m` in `lang` (`csharp`, `java` or `typescript`), with the JSON
/// Schema document of the API alongside.
pub func generateSdk(m: in ApiModel, lang: in String): SdkOutput {
  val generated = if lang == "csharp" {
    generateCSharp(m)
  } else if lang == "java" {
    generateJava(m)
  } else if lang == "typescript" {
    generateTypeScript(m)
  } else {
    val errs: List[String] = newList()
    errs.add("error: unknown SDK language \"" + lang + "\" (expected csharp, java or typescript)")
    SdkOutput(files = newList(), errors = errs)
  }
  if generated.errors.count == 0 {
    generated.files.add(SdkFile(path = m.packageName + ".schema.json", content = generateSchema(m)))
  }
  generated
}
