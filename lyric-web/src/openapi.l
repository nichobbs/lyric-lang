//! Web.OpenApi — OpenAPI 3.1 spec type vocabulary and code-first spec builder.
//!
//! Two uses:
//!
//! 1. Code-first spec builder: populate a `Spec` value in your package and
//!    either render it with `specToJson` (to write `openapi.json` at build
//!    time) or attach it to a running server with `Web.withSpec(router,
//!    spec)`, which serves the live JSON at `/openapi.json` and a Swagger
//!    UI page at `/swagger` (#5360).
//!
//! 2. Spec-first reference: `lyric generate openapi spec.yaml` uses these types
//!    internally to represent the parsed spec before generating .l stubs.
//!
//! OpenAPI → Lyric type mapping (used by code generation):
//!
//!   OpenAPI schema               Lyric type
//!   ─────────────────────────    ────────────────────────────────────────────
//!   type: integer, format: int32 Int
//!   type: integer, format: int64 Long
//!   type: number,  format: float Float
//!   type: number,  format: double Double
//!   type: boolean                Bool
//!   type: string                 String
//!   type: string, nullable: true Option[String]
//!   type: string, enum: [a,b]    pub enum T { case A; case B }
//!   type: object, properties:{}  pub record T { field: Type; ... }
//!   type: array, items: T        slice[T]
//!   $ref: '#/components/schemas/X'  the generated Lyric type for schema X
//!
//! OpenAPI constraints → requires: clauses (spec-first code generation):
//!
//!   minimum: N (integer)      requires: param >= N
//!   maximum: N (integer)      requires: param <= N
//!   exclusiveMinimum: N       requires: param > N
//!   exclusiveMaximum: N       requires: param < N
//!   minLength: N              requires: param.length >= N
//!   maxLength: N              requires: param.length <= N
//!   minItems: N               requires: param.length >= N  (on list params)
//!   maxItems: N               requires: param.length <= N
//!   pattern: "regex"          // NOTE: can't express in Lyric requires: v1;
//!                             //   emitted as a // TODO comment in the stub.
//!   required: true (body)     the parameter is non-optional (no Option[T])
//!   required: false / absent  the parameter is Option[T]
//!   format: int32+minimum+maximum together emit an Int range N..=M subtype
@runtime_checked
package Web.OpenApi

import Std.Core
import Std.Collections
import Std.Json

// ─── Info ─────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record Contact {
  name: String
  email: String
  url: String
}

@stable(since = "0.1")
pub record License {
  name: String
  url: String
}

@stable(since = "0.1")
pub record Info {
  title: String
  version: String
  description: String
  contact: Option[Contact]
  license: Option[License]
}

// ─── Schema ───────────────────────────────────────────────────────────────────
/// JSON Schema type keyword values used in OpenAPI 3.1.
/// A payload-free `union` rather than `enum`: co-compiling a payload-free
/// `enum` with a closure (as `Web`'s `Route`/`Middleware` now uses) crashes
/// the self-hosted MSIL backend's closure lowering (issue #5361); `union`
/// with an identical case list is unaffected, mirroring the enum -> union
/// workaround D099 applied to `lyric-health`'s `CheckGroup` for a related
/// cross-package enum-dispatch bug.
@stable(since = "0.1")
pub union SchemaType {
  case SchemaString
  case SchemaInteger
  case SchemaNumber
  case SchemaBoolean
  case SchemaArray
  case SchemaObject
  case SchemaNull
}

/// A named property entry in an object schema.
/// Uses a $ref string to reference the property's schema by name.
@stable(since = "0.1")
pub record PropertyEntry {
  name: String
  schemaRef: String    // "$ref" string or inline type name
}

/// OpenAPI 3.1 schema object (simplified — covers all types emitted by
/// `lyric web spec` and consumed by `lyric generate openapi`).
/// Nested schemas (items, properties) are represented by $ref strings
/// rather than inline schema objects to avoid recursive type definitions.
@stable(since = "0.1")
pub record Schema {
  schemaType: Option[SchemaType]
  format: String                // "int32" | "int64" | "float" | "double" | "date-time" | ""
  description: String
  nullable: Bool
  deprecated: Bool
  // Numeric constraints
  minimum: Option[Int]
  maximum: Option[Int]
  exclusiveMinimum: Option[Int]
  exclusiveMaximum: Option[Int]
  // String constraints
  minLength: Option[Int]
  maxLength: Option[Int]
  pattern: String                // regex; empty if absent
  // Enum values (string literals; type is always SchemaType.String when non-empty)
  enumValues: slice[String]
  // Array — itemsRef is a $ref string (e.g. "#/components/schemas/Foo") or ""
  itemsRef: String
  minItems: Option[Int]
  maxItems: Option[Int]
  // Object
  properties: slice[PropertyEntry]
  required: slice[String]         // required property names
  // Composition
  ref: String                // "$ref" value; non-empty → use instead of type
}

/// A named schema entry for the components/schemas section.
@stable(since = "0.1")
pub record SchemaEntry {
  name: String
  schema: Schema
}

/// Construct a simple scalar schema.
@stable(since = "0.1")
pub func scalarSchema(t: in SchemaType, format: in String, description: in String): Schema {
  val emptyEnums: List[String] = newList()
  val emptyProps: List[PropertyEntry] = newList()
  val emptyReq: List[String] = newList()
  return Schema(
    schemaType = Some(t),
    format = format,
    description = description,
    nullable = false,
    deprecated = false,
    minimum = None,
    maximum = None,
    exclusiveMinimum = None,
    exclusiveMaximum = None,
    minLength = None,
    maxLength = None,
    pattern = "",
    enumValues = emptyEnums.toArray(),
    itemsRef = "",
    minItems = None,
    maxItems = None,
    properties = emptyProps.toArray(),
    required = emptyReq.toArray(),
    ref = ""
  )
}

/// Construct a $ref schema.
@stable(since = "0.1")
pub func refSchema(name: in String): Schema {
  val emptyEnums: List[String] = newList()
  val emptyProps: List[PropertyEntry] = newList()
  val emptyReq: List[String] = newList()
  return Schema(
    schemaType = None,
    format = "",
    description = "",
    nullable = false,
    deprecated = false,
    minimum = None,
    maximum = None,
    exclusiveMinimum = None,
    exclusiveMaximum = None,
    minLength = None,
    maxLength = None,
    pattern = "",
    enumValues = emptyEnums.toArray(),
    itemsRef = "",
    minItems = None,
    maxItems = None,
    properties = emptyProps.toArray(),
    required = emptyReq.toArray(),
    ref = "#/components/schemas/" + name
  )
}

// ─── Parameters and request body ─────────────────────────────────────────────
/// A payload-free `union` — see `SchemaType`'s doc comment above (issue #5361).
@stable(since = "0.1")
pub union ParameterLocation {
  case Path
  case Query
  case Header
  case Cookie
}

@stable(since = "0.1")
pub record Parameter {
  name: String
  location: ParameterLocation
  required: Bool
  description: String
  deprecated: Bool
  schema: Schema
}

@stable(since = "0.1")
pub record MediaType {
  contentType: String    // "application/json"
  schema: Schema
}

@stable(since = "0.1")
pub record RequestBody {
  description: String
  required: Bool
  content: slice[MediaType]
}

// ─── Responses ────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record ApiResponse {
  statusCode: Int
  description: String
  content: slice[MediaType]    // empty → no body
}

// ─── Operations ───────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record Operation {
  operationId: String
  summary: String
  description: String
  tags: slice[String]
  parameters: slice[Parameter]
  requestBody: Option[RequestBody]
  responses: slice[ApiResponse]
  deprecated: Bool
}

// ─── Paths ────────────────────────────────────────────────────────────────────
/// A single path item binding URL patterns to HTTP-method operations.
@stable(since = "0.1")
pub record PathItem {
  pattern: String
  get: Option[Operation]
  post: Option[Operation]
  put: Option[Operation]
  delete: Option[Operation]
  patch: Option[Operation]
  head: Option[Operation]
  options: Option[Operation]
}

// ─── Spec ─────────────────────────────────────────────────────────────────────
/// Top-level OpenAPI 3.1 document.
@stable(since = "0.1")
pub record Spec {
  openapi: String              // always "3.1.0"
  info: Info
  paths: slice[PathItem]
  schemas: slice[SchemaEntry]  // components/schemas entries
  servers: slice[String]       // server URL strings
}

/// Construct an empty spec with the given metadata.
@stable(since = "0.1")
pub func newSpec(title: in String, version: in String, description: in String): Spec
  requires: title.length > 0
  requires: version.length > 0
{
  val info = Info(title = title, version = version, description = description, contact = None, license = None)
  val emptyPaths: List[PathItem] = newList()
  val emptySchemas: List[SchemaEntry] = newList()
  val emptyServers: List[String] = newList()
  return Spec(
    openapi = "3.1.0",
    info = info,
    paths = emptyPaths.toArray(),
    schemas = emptySchemas.toArray(),
    servers = emptyServers.toArray()
  )
}

/// Add a server URL to the spec.
@stable(since = "0.1")
pub func addServer(spec: in Spec, url: in String): Spec {
  val acc: List[String] = newList()
  for s in spec.servers {
    acc.add(s)
  }
  acc.add(url)
  return Spec(
    openapi = spec.openapi,
    info = spec.info,
    paths = spec.paths,
    schemas = spec.schemas,
    servers = acc.toArray()
  )
}

/// Add a reusable schema component.
@stable(since = "0.1")
pub func addSchema(spec: in Spec, name: in String, schema: in Schema): Spec
  requires: name.length > 0
{
  val schemaItem = SchemaEntry(name = name, schema = schema)
  val acc: List[SchemaEntry] = newList()
  for s in spec.schemas {
    acc.add(s)
  }
  acc.add(schemaItem)
  return Spec(
    openapi = spec.openapi,
    info = spec.info,
    paths = spec.paths,
    schemas = acc.toArray(),
    servers = spec.servers
  )
}

/// Add a path item to the spec.
@stable(since = "0.1")
pub func addPath(spec: in Spec, item: in PathItem): Spec {
  val acc: List[PathItem] = newList()
  for p in spec.paths {
    acc.add(p)
  }
  acc.add(item)
  return Spec(
    openapi = spec.openapi,
    info = spec.info,
    paths = acc.toArray(),
    schemas = spec.schemas,
    servers = spec.servers
  )
}

// ─── JSON serialization (issue #5360) ────────────────────────────────────────
// Renders a `Spec` value into an OpenAPI 3.1 JSON document string, for
// `Web.withSpec` to serve live at `/openapi.json`. Every `$ref`-shaped field
// (`Schema.ref`, `Schema.itemsRef`, `PropertyEntry.schemaRef`) is emitted
// verbatim as the `$ref` value — this module's own constructors
// (`refSchema`) already produce a fully-formed `#/components/schemas/...`
// path, so no further prefixing happens here.
func joinComma(parts: in List[String]): String {
  var acc = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + parts[i]
    i = i + 1
  }
  return acc
}

func jStr(s: in String): String {
  return encodeString(s)
}

func jBool(b: in Bool): String {
  if b {
    return "true"
  }
  return "false"
}

func contactToJson(c: in Contact): String {
  val parts: List[String] = newList()
  if c.name.length > 0 {
    parts.add("\"name\":" + jStr(c.name))
  }
  if c.email.length > 0 {
    parts.add("\"email\":" + jStr(c.email))
  }
  if c.url.length > 0 {
    parts.add("\"url\":" + jStr(c.url))
  }
  return "{" + joinComma(parts) + "}"
}

func licenseToJson(l: in License): String {
  val parts: List[String] = newList()
  if l.name.length > 0 {
    parts.add("\"name\":" + jStr(l.name))
  }
  if l.url.length > 0 {
    parts.add("\"url\":" + jStr(l.url))
  }
  return "{" + joinComma(parts) + "}"
}

func infoToJson(info: in Info): String {
  val parts: List[String] = newList()
  parts.add("\"title\":" + jStr(info.title))
  parts.add("\"version\":" + jStr(info.version))
  if info.description.length > 0 {
    parts.add("\"description\":" + jStr(info.description))
  }
  match info.contact {
    case Some(c) -> parts.add("\"contact\":" + contactToJson(c))
    case None -> ()
  }
  match info.license {
    case Some(l) -> parts.add("\"license\":" + licenseToJson(l))
    case None -> ()
  }
  return "{" + joinComma(parts) + "}"
}

func schemaTypeToJson(t: in SchemaType): String {
  match t {
    case SchemaString -> "\"string\""
    case SchemaInteger -> "\"integer\""
    case SchemaNumber -> "\"number\""
    case SchemaBoolean -> "\"boolean\""
    case SchemaArray -> "\"array\""
    case SchemaObject -> "\"object\""
    case SchemaNull -> "\"null\""
  }
}

func schemaToJson(s: in Schema): String {
  // A non-empty `$ref` replaces the whole schema body (OpenAPI 3.1 allows
  // sibling keywords alongside `$ref`, but this vocabulary never
  // populates both — `refSchema`/`scalarSchema` are mutually exclusive
  // constructors).
  if s.ref.length > 0 {
    return "{\"$ref\":" + jStr(s.ref) + "}"
  }
  val parts: List[String] = newList()
  match s.schemaType {
    case Some(t) -> parts.add("\"type\":" + schemaTypeToJson(t))
    case None -> ()
  }
  if s.format.length > 0 {
    parts.add("\"format\":" + jStr(s.format))
  }
  if s.description.length > 0 {
    parts.add("\"description\":" + jStr(s.description))
  }
  if s.nullable {
    parts.add("\"nullable\":true")
  }
  if s.deprecated {
    parts.add("\"deprecated\":true")
  }
  match s.minimum {
    case Some(n) -> parts.add("\"minimum\":" + n.toString())
    case None -> ()
  }
  match s.maximum {
    case Some(n) -> parts.add("\"maximum\":" + n.toString())
    case None -> ()
  }
  match s.exclusiveMinimum {
    case Some(n) -> parts.add("\"exclusiveMinimum\":" + n.toString())
    case None -> ()
  }
  match s.exclusiveMaximum {
    case Some(n) -> parts.add("\"exclusiveMaximum\":" + n.toString())
    case None -> ()
  }
  match s.minLength {
    case Some(n) -> parts.add("\"minLength\":" + n.toString())
    case None -> ()
  }
  match s.maxLength {
    case Some(n) -> parts.add("\"maxLength\":" + n.toString())
    case None -> ()
  }
  if s.pattern.length > 0 {
    parts.add("\"pattern\":" + jStr(s.pattern))
  }
  if s.enumValues.length > 0 {
    val enumParts: List[String] = newList()
    for e in s.enumValues {
      enumParts.add(jStr(e))
    }
    parts.add("\"enum\":[" + joinComma(enumParts) + "]")
  }
  if s.itemsRef.length > 0 {
    parts.add("\"items\":{\"$ref\":" + jStr(s.itemsRef) + "}")
  }
  match s.minItems {
    case Some(n) -> parts.add("\"minItems\":" + n.toString())
    case None -> ()
  }
  match s.maxItems {
    case Some(n) -> parts.add("\"maxItems\":" + n.toString())
    case None -> ()
  }
  if s.properties.length > 0 {
    val propParts: List[String] = newList()
    for p in s.properties {
      propParts.add(jStr(p.name) + ":{\"$ref\":" + jStr(p.schemaRef) + "}")
    }
    parts.add("\"properties\":{" + joinComma(propParts) + "}")
  }
  if s.required.length > 0 {
    val reqParts: List[String] = newList()
    for r in s.required {
      reqParts.add(jStr(r))
    }
    parts.add("\"required\":[" + joinComma(reqParts) + "]")
  }
  return "{" + joinComma(parts) + "}"
}

func parameterLocationToJson(loc: in ParameterLocation): String {
  match loc {
    case Path -> "\"path\""
    case Query -> "\"query\""
    case Header -> "\"header\""
    case Cookie -> "\"cookie\""
  }
}

func parameterToJson(p: in Parameter): String {
  val parts: List[String] = newList()
  parts.add("\"name\":" + jStr(p.name))
  parts.add("\"in\":" + parameterLocationToJson(p.location))
  parts.add("\"required\":" + jBool(p.required))
  if p.description.length > 0 {
    parts.add("\"description\":" + jStr(p.description))
  }
  if p.deprecated {
    parts.add("\"deprecated\":true")
  }
  parts.add("\"schema\":" + schemaToJson(p.schema))
  return "{" + joinComma(parts) + "}"
}

func mediaTypeMapToJson(content: in slice[MediaType]): String {
  val parts: List[String] = newList()
  for m in content {
    parts.add(jStr(m.contentType) + ":{\"schema\":" + schemaToJson(m.schema) + "}")
  }
  return "{" + joinComma(parts) + "}"
}

func requestBodyToJson(rb: in RequestBody): String {
  val parts: List[String] = newList()
  if rb.description.length > 0 {
    parts.add("\"description\":" + jStr(rb.description))
  }
  parts.add("\"required\":" + jBool(rb.required))
  parts.add("\"content\":" + mediaTypeMapToJson(rb.content))
  return "{" + joinComma(parts) + "}"
}

func responseToJson(r: in ApiResponse): String {
  val parts: List[String] = newList()
  parts.add("\"description\":" + jStr(r.description))
  if r.content.length > 0 {
    parts.add("\"content\":" + mediaTypeMapToJson(r.content))
  }
  return "{" + joinComma(parts) + "}"
}

func responsesMapToJson(responses: in slice[ApiResponse]): String {
  val parts: List[String] = newList()
  for r in responses {
    parts.add(jStr(r.statusCode.toString()) + ":" + responseToJson(r))
  }
  return "{" + joinComma(parts) + "}"
}

func operationToJson(op: in Operation): String {
  val parts: List[String] = newList()
  if op.operationId.length > 0 {
    parts.add("\"operationId\":" + jStr(op.operationId))
  }
  if op.summary.length > 0 {
    parts.add("\"summary\":" + jStr(op.summary))
  }
  if op.description.length > 0 {
    parts.add("\"description\":" + jStr(op.description))
  }
  if op.tags.length > 0 {
    val tagParts: List[String] = newList()
    for t in op.tags {
      tagParts.add(jStr(t))
    }
    parts.add("\"tags\":[" + joinComma(tagParts) + "]")
  }
  if op.parameters.length > 0 {
    val paramParts: List[String] = newList()
    for p in op.parameters {
      paramParts.add(parameterToJson(p))
    }
    parts.add("\"parameters\":[" + joinComma(paramParts) + "]")
  }
  match op.requestBody {
    case Some(rb) -> parts.add("\"requestBody\":" + requestBodyToJson(rb))
    case None -> ()
  }
  parts.add("\"responses\":" + responsesMapToJson(op.responses))
  if op.deprecated {
    parts.add("\"deprecated\":true")
  }
  return "{" + joinComma(parts) + "}"
}

func pathItemToJson(item: in PathItem): String {
  val parts: List[String] = newList()
  match item.get {
    case Some(o) -> parts.add("\"get\":" + operationToJson(o))
    case None -> ()
  }
  match item.post {
    case Some(o) -> parts.add("\"post\":" + operationToJson(o))
    case None -> ()
  }
  match item.put {
    case Some(o) -> parts.add("\"put\":" + operationToJson(o))
    case None -> ()
  }
  match item.delete {
    case Some(o) -> parts.add("\"delete\":" + operationToJson(o))
    case None -> ()
  }
  match item.patch {
    case Some(o) -> parts.add("\"patch\":" + operationToJson(o))
    case None -> ()
  }
  match item.head {
    case Some(o) -> parts.add("\"head\":" + operationToJson(o))
    case None -> ()
  }
  match item.options {
    case Some(o) -> parts.add("\"options\":" + operationToJson(o))
    case None -> ()
  }
  return "{" + joinComma(parts) + "}"
}

func pathsMapToJson(paths: in slice[PathItem]): String {
  val parts: List[String] = newList()
  for p in paths {
    parts.add(jStr(p.pattern) + ":" + pathItemToJson(p))
  }
  return "{" + joinComma(parts) + "}"
}

func schemasMapToJson(schemas: in slice[SchemaEntry]): String {
  val parts: List[String] = newList()
  for e in schemas {
    parts.add(jStr(e.name) + ":" + schemaToJson(e.schema))
  }
  return "{" + joinComma(parts) + "}"
}

/// Render `spec` as an OpenAPI 3.1 JSON document string. Used by
/// `Web.withSpec` to serve the spec live at `/openapi.json`; also usable
/// directly to write `openapi.json` to disk at build time.
@stable(since = "0.2")
pub func specToJson(spec: in Spec): String {
  val parts: List[String] = newList()
  parts.add("\"openapi\":" + jStr(spec.openapi))
  parts.add("\"info\":" + infoToJson(spec.info))
  if spec.servers.length > 0 {
    val serverParts: List[String] = newList()
    for s in spec.servers {
      serverParts.add("{\"url\":" + jStr(s) + "}")
    }
    parts.add("\"servers\":[" + joinComma(serverParts) + "]")
  }
  parts.add("\"paths\":" + pathsMapToJson(spec.paths))
  if spec.schemas.length > 0 {
    parts.add("\"components\":{\"schemas\":" + schemasMapToJson(spec.schemas) + "}")
  }
  return "{" + joinComma(parts) + "}"
}
