//! openapi_parser.l — OpenAPI 3.x spec parser for the lyric openapi generator.
//!
//! Parses the subset of OpenAPI 3.0/3.1 needed to generate a typed Lyric REST
//! client: paths, operations (get/post/put/patch/delete/head/options), path and
//! query parameters, JSON request/response bodies, and inline object/scalar
//! schemas.  Unknown fields are silently ignored.
//!
//! All types in the parsed model use Lyric type-name strings (e.g. "Int",
//! "String") rather than a recursive SchemaKind union, which avoids needing
//! generic recursive types in the bootstrap compiler.
package Lyric.OpenApiParser

import Std.Core
import Std.Collections
import Std.Json
import Std.String as Str

// ─── JsonValueKind constants ──────────────────────────────────────────────
// 0=Undefined, 1=Object, 2=Array, 3=String, 4=Number, 5=True, 6=False, 7=Null
// ─── Public record types ──────────────────────────────────────────────────
pub record ParsedProperty {
  name: String
  lyricType: String
  required: Bool
}

pub record ParsedParam {
  name: String
  location: String
  required: Bool
  lyricType: String
}

pub record ParsedOp {
  operationId: String
  verb: String
  path: String
  summary: String
  description: String
  pathParams: List[ParsedParam]
  queryParams: List[ParsedParam]
  hasRequestBody: Bool
  requestBodyIsObject: Bool
  requestBodyProps: List[ParsedProperty]
  successRespIsObject: Bool
  successRespProps: List[ParsedProperty]
  tags: List[String]
}

pub record ParsedSpec {
  title: String
  descr: String
  version: String
  basePath: String
  operations: List[ParsedOp]
  // ─── JSON navigation helpers ──────────────────────────────────────────────
}

func strProp(elem: in JsonElement, key: in String): String {
  match tryGetProperty(elem, key) {
    case None -> ""
    case Some(v) -> if valueKind(v) == 3 { getString(v) } else { "" }
  }
}

func boolProp(elem: in JsonElement, key: in String, def: in Bool): Bool {
  match tryGetProperty(elem, key) {
    case None -> def
    case Some(v) -> if valueKind(v) == 5 { true } else if valueKind(v) == 6 { false } else { def }
  }
}

func tryObj(elem: in JsonElement, key: in String): Option[JsonElement] {
  match tryGetProperty(elem, key) {
    case None -> None
    case Some(v) -> if valueKind(v) == 1 { Some(value = v) } else { None }
  }
}

func tryArr(elem: in JsonElement, key: in String): Option[JsonElement] {
  match tryGetProperty(elem, key) {
    case None -> None
    case Some(v) -> if valueKind(v) == 2 { Some(value = v) } else { None }
  }
}

// ─── Schema helpers ───────────────────────────────────────────────────────
func listHasStr(list: in List[String], s: in String): Bool {
  var i = 0
  var found = false
  while i < list.count and not found {
    if list[i] == s {
      found = true
    }
    i = i + 1
  }
  found
}

func schemaToLyricType(elem: in JsonElement): String {
  val ty = strProp(elem, "type")
  if ty == "string" {
    return "String"
  }
  if ty == "integer" {
    return "Int"
  }
  if ty == "number" {
    return "Double"
  }
  if ty == "boolean" {
    return "Bool"
  }
  if ty == "array" {
    match tryObj(elem, "items") {
      case None -> return "List[String]"
      case Some(items) -> return "List[" + schemaToLyricType(items) + "]"
    }
  }
  "String"
}

func isObjectSchema(elem: in JsonElement): Bool {
  val ty = strProp(elem, "type")
  if ty == "object" {
    return true
  }
  if ty == "" {
    match tryObj(elem, "properties") {
      case None -> return false
      case Some(_) -> return true
    }
  }
  false
}

func buildRequiredList(schemaElem: in JsonElement): List[String] {
  val req: List[String] = newList()
  match tryArr(schemaElem, "required") {
    case None -> ()
    case Some(arr) -> {
      var en: JsonArrayEnumerator = enumerateArray(arr)
      while arrayMoveNext(en) {
        val item = arrayCurrent(en)
        if valueKind(item) == 3 {
          req.add(getString(item))
        }
      }
    }
  }
  req
}

func parseObjectProps(propsElem: in JsonElement, reqList: in List[String]): List[ParsedProperty] {
  val result: List[ParsedProperty] = newList()
  var en: JsonObjectEnumerator = enumerateObject(propsElem)
  while objectMoveNext(en) {
    val prop = objectCurrent(en)
    val propName = propertyName(prop)
    val propVal = propertyValue(prop)
    val lt = schemaToLyricType(propVal)
    val req = listHasStr(reqList, propName)
    result.add(ParsedProperty(name = propName, lyricType = lt, required = req))
  }
  result
}

func schemaBodyProps(schemaElem: in JsonElement): List[ParsedProperty] {
  val empty: List[ParsedProperty] = newList()
  if not isObjectSchema(schemaElem) {
    return empty
  }
  val req = buildRequiredList(schemaElem)
  match tryObj(schemaElem, "properties") {
    case None -> empty
    case Some(propsEl) -> parseObjectProps(propsEl, req)
  }
}

// ─── Parameter parsing ────────────────────────────────────────────────────
func parseParameter(elem: in JsonElement): ParsedParam {
  val name = strProp(elem, "name")
  val location = Str.toLower(strProp(elem, "in"))
  val required = boolProp(elem, "required", false)
  val lt = match tryObj(elem, "schema") { case None -> "String"; case Some(s) -> schemaToLyricType(s) }
  ParsedParam(name = name, location = location, required = required, lyricType = lt)
}

func parseParamList(arr: in JsonElement): List[ParsedParam] {
  val result: List[ParsedParam] = newList()
  var en: JsonArrayEnumerator = enumerateArray(arr)
  while arrayMoveNext(en) {
    result.add(parseParameter(arrayCurrent(en)))
  }
  result
}

// ─── Tags parsing ─────────────────────────────────────────────────────────
func parseTagList(elem: in JsonElement): List[String] {
  val result: List[String] = newList()
  match tryArr(elem, "tags") {
    case None -> ()
    case Some(arr) -> {
      var en: JsonArrayEnumerator = enumerateArray(arr)
      while arrayMoveNext(en) {
        val item = arrayCurrent(en)
        if valueKind(item) == 3 {
          result.add(getString(item))
        }
      }
    }
  }
  result
}

// ─── Operation ID synthesis ───────────────────────────────────────────────
func synthesizeOpId(verb: in String, path: in String): String {
  val parts = Str.split(path, "/")
  var i = 0
  var slug = ""
  while i < parts.length {
    val seg = parts[i]
    val segLen = Str.length(seg)
    if segLen > 0 {
      if Str.startsWith(seg, "{") and Str.endsWith(seg, "}") {
        val inner = Str.substring(seg, 1, segLen - 2)
        if Str.length(inner) > 0 {
          slug = slug + "By" + Str.toUpper(Str.substring(inner, 0, 1)) + Str.substring(inner, 1, Str.length(inner) - 1)
        }
      } else {
        slug = slug + Str.toUpper(Str.substring(seg, 0, 1)) + Str.substring(seg, 1, segLen - 1)
      }
    }
    i = i + 1
  }
  verb + slug
}

// ─── Operation parsing ────────────────────────────────────────────────────
func parseOp(verb: in String, path: in String, elem: in JsonElement, pathLevelParams: in List[ParsedParam]): ParsedOp {
  // Collect op-level parameters then merge path-level ones (no duplicates).
  val allParams: List[ParsedParam] = match tryArr(elem, "parameters") {
    case None -> newList()
    case Some(arr) -> parseParamList(arr)
  }
  val opParamNames: List[String] = newList()
  var pi = 0
  while pi < allParams.count {
    opParamNames.add(allParams[pi].name)
    pi = pi + 1
  }
  var pli = 0
  while pli < pathLevelParams.count {
    if not listHasStr(opParamNames, pathLevelParams[pli].name) {
      allParams.add(pathLevelParams[pli])
    }
    pli = pli + 1
  }

  // Split by location.
  val pathParams: List[ParsedParam] = newList()
  val queryParams: List[ParsedParam] = newList()
  var ci = 0
  while ci < allParams.count {
    val p = allParams[ci]
    if p.location == "path" {
      pathParams.add(p)
    } else if p.location == "query" {
      queryParams.add(p)
    }
    ci = ci + 1
  }

  // Request body.
  var hasBody: Bool = false
  var bodyIsObject: Bool = false
  val bodyProps: List[ParsedProperty] = newList()
  match tryObj(elem, "requestBody") {
    case None -> ()
    case Some(rb) -> {
      hasBody = true
      match tryObj(rb, "content") {
        case None -> ()
        case Some(content) -> match tryObj(content, "application/json") { case None -> (); case Some(mt) -> match tryObj(mt, "schema") { case None -> (); case Some(schema) -> { bodyIsObject = isObjectSchema(schema); val props = schemaBodyProps(schema); var bpi = 0; while bpi < props.count { bodyProps.add(props[bpi]); bpi = bpi + 1 } } } }
      }
    }
  }

  // First 2xx (or "default") response schema.
  var succIsObject: Bool = false
  val succProps: List[ParsedProperty] = newList()
  match tryObj(elem, "responses") {
    case None -> ()
    case Some(responses) -> {
      var found = false
      var en: JsonObjectEnumerator = enumerateObject(responses)
      while objectMoveNext(en) and not found {
        val rProp = objectCurrent(en)
        val code = propertyName(rProp)
        if Str.startsWith(code, "2") or code == "default" {
          found = true
          val rElem = propertyValue(rProp)
          match tryObj(rElem, "content") {
            case None -> ()
            case Some(content) -> match tryObj(content, "application/json") { case None -> (); case Some(mt) -> match tryObj(mt, "schema") { case None -> (); case Some(schema) -> { succIsObject = isObjectSchema(schema); val props = schemaBodyProps(schema); var si = 0; while si < props.count { succProps.add(props[si]); si = si + 1 } } } }
          }
        }
      }
    }
  }

  // OperationId: spec-provided or synthesized.
  var opId = strProp(elem, "operationId")
  if Str.length(opId) == 0 {
    opId = synthesizeOpId(verb, path)
  }

  ParsedOp(
    operationId = opId,
    verb = verb,
    path = path,
    summary = strProp(elem, "summary"),
    description = strProp(elem, "description"),
    pathParams = pathParams,
    queryParams = queryParams,
    hasRequestBody = hasBody,
    requestBodyIsObject = bodyIsObject,
    requestBodyProps = bodyProps,
    successRespIsObject = succIsObject,
    successRespProps = succProps,
    tags = parseTagList(elem)
  )
}

// ─── Paths / spec parsing ─────────────────────────────────────────────────
func parsePaths(root: in JsonElement): List[ParsedOp] {
  val result: List[ParsedOp] = newList()
  match tryObj(root, "paths") {
    case None -> ()
    case Some(paths) -> {
      var pathEn: JsonObjectEnumerator = enumerateObject(paths)
      while objectMoveNext(pathEn) {
        val pathProp = objectCurrent(pathEn)
        val path = propertyName(pathProp)
        val pathItem = propertyValue(pathProp)

        val pathLevelParams: List[ParsedParam] = match tryArr(pathItem, "parameters") {
          case None -> newList()
          case Some(arr) -> parseParamList(arr)
        }

        var opEn: JsonObjectEnumerator = enumerateObject(pathItem)
        while objectMoveNext(opEn) {
          val opProp = objectCurrent(opEn)
          val verb = Str.toLower(propertyName(opProp))
          val isVerb = verb == "get" or verb == "post" or verb == "put" or verb == "patch" or verb == "delete" or verb == "head" or
            verb == "options"
          if isVerb {
            result.add(parseOp(verb, path, propertyValue(opProp), pathLevelParams))
          }
        }
      }
    }
  }
  result
}

func stripBasePath(url: in String): String {
  var s = url
  if Str.endsWith(s, "/") {
    s = Str.substring(s, 0, Str.length(s) - 1)
  }
  match Str.indexOf(s, "{") {
    case None -> s
    case Some(idx) -> {
      val trimmed = Str.trimEnd(Str.substring(s, 0, idx))
      if Str.endsWith(trimmed, "/") {
        Str.substring(trimmed, 0, Str.length(trimmed) - 1)
      } else {
        trimmed
      }
    }
  }
}

/// Parse an OpenAPI 3.x spec from a JSON string.
pub func parseSpec(json: in String): Result[ParsedSpec, String] {
  val doc = parseJson(json)
  val root = rootElement(doc)

  var title = ""
  var descr = ""
  var version = ""
  match tryObj(root, "info") {
    case None -> ()
    case Some(info) -> {
      title = strProp(info, "title")
      descr = strProp(info, "description")
      version = strProp(info, "version")
    }
  }
  if Str.length(title) == 0 {
    title = "Api"
  }
  if Str.length(version) == 0 {
    version = "0.0.0"
  }

  var basePath = ""
  match tryArr(root, "servers") {
    case None -> ()
    case Some(arr) -> {
      var en: JsonArrayEnumerator = enumerateArray(arr)
      if arrayMoveNext(en) {
        val first = arrayCurrent(en)
        val url = strProp(first, "url")
        basePath = stripBasePath(url)
      }
    }
  }

  val operations = parsePaths(root)

  Ok(value = ParsedSpec(title = title, descr = descr, version = version, basePath = basePath, operations = operations))
}
