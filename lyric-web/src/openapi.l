//! Web.OpenApi — OpenAPI 3.1 spec type vocabulary and code-first spec builder.
//!
//! Two uses:
//!
//! 1. Code-first spec builder: populate Spec values in your package and pass
//!    them to `lyric web spec` via the `Lyric.Web.OpenApi.Spec` export, or
//!    serve them live via `Web.start(router)` with swagger enabled.
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
@stable(since = "0.1")
pub enum SchemaType {
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
@stable(since = "0.1")
pub enum ParameterLocation {
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
