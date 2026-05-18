// Web.OpenApi — OpenAPI 3.1 spec type vocabulary and code-first spec builder.
//
// Two uses:
//
// 1. Code-first spec builder: populate Spec values in your package and pass
//    them to `lyric web spec` via the `Lyric.Web.OpenApi.Spec` export, or
//    serve them live via `Web.start(router)` with `Server.swaggerEnabled = true`.
//
// 2. Spec-first reference: `lyric generate openapi spec.yaml` uses these types
//    internally to represent the parsed spec before generating .l stubs.
//
// OpenAPI → Lyric type mapping (used by code generation):
//
//   OpenAPI schema               Lyric type
//   ─────────────────────────    ────────────────────────────────────────────
//   type: integer, format: int32 Int
//   type: integer, format: int64 Long
//   type: number,  format: float Float
//   type: number,  format: double Double
//   type: boolean                Bool
//   type: string                 String
//   type: string, nullable: true Option[String]
//   type: string, enum: [a,b]    pub enum T { case A; case B }
//   type: object, properties:{}  pub record T { field: Type; ... }
//   type: array, items: T        [T]   (Lyric list)
//   $ref: '#/components/schemas/X'  the generated Lyric type for schema X
//
// OpenAPI constraints → requires: clauses (spec-first code generation):
//
//   minimum: N (integer)      requires: param >= N
//   maximum: N (integer)      requires: param <= N
//   exclusiveMinimum: N       requires: param > N
//   exclusiveMaximum: N       requires: param < N
//   minLength: N              requires: param.length >= N
//   maxLength: N              requires: param.length <= N
//   minItems: N               requires: param.length >= N  (on list params)
//   maxItems: N               requires: param.length <= N
//   pattern: "regex"          // NOTE: can't express in Lyric requires: v1;
//                             //   emitted as a // TODO comment in the stub.
//   required: true (body)     the parameter is non-optional (no Option[T])
//   required: false / absent  the parameter is Option[T]
//   format: int32+minimum+maximum together emit an Int range N..=M subtype

@runtime_checked
package Web.OpenApi

import Std.Core

// ─── Info ─────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Contact {
  name:  String
  email: String
  url:   String
}

@stable(since="0.1")
pub record License {
  name: String
  url:  String
}

@stable(since="0.1")
pub record Info {
  title:       String
  version:     String
  description: String
  contact:     Option[Contact]
  license:     Option[License]
}

// ─── Schema ───────────────────────────────────────────────────────────────────

/// JSON Schema type keyword values used in OpenAPI 3.1.
@stable(since="0.1")
pub enum SchemaType {
  case String
  case Integer
  case Number
  case Boolean
  case Array
  case Object
  case Null
}

/// OpenAPI 3.1 schema object (simplified — covers all types emitted by
/// `lyric web spec` and consumed by `lyric generate openapi`).
@stable(since="0.1")
pub record Schema {
  type:             Option[SchemaType]
  format:           String                // "int32" | "int64" | "float" | "double" | "date-time" | ""
  description:      String
  nullable:         Bool
  deprecated:       Bool
  // Numeric constraints
  minimum:          Option[Int]
  maximum:          Option[Int]
  exclusiveMinimum: Option[Int]
  exclusiveMaximum: Option[Int]
  // String constraints
  minLength:        Option[Int]
  maxLength:        Option[Int]
  pattern:          String                // regex; empty if absent
  // Enum values (string literals; type is always SchemaType.String when non-empty)
  enum:             [String]
  // Array
  items:            Option[SchemaRef]
  minItems:         Option[Int]
  maxItems:         Option[Int]
  // Object
  properties:       [(String, SchemaRef)] // (name, schema)
  required:         [String]              // required property names
  // Composition
  ref:              String                // "$ref" value; non-empty → use instead of type
}

/// A schema reference is either an inline schema or a $ref string.
/// In v1 the two cases are encoded in a single Schema record:
/// when `ref` is non-empty it is a $ref; otherwise it is an inline schema.
pub type SchemaRef = Schema

/// Construct a simple scalar schema.
@stable(since="0.1")
pub func scalarSchema(t: in SchemaType, format: in String, description: in String): Schema {
  return Schema(
    type = Some(t), format = format, description = description, nullable = false,
    deprecated = false, minimum = None, maximum = None,
    exclusiveMinimum = None, exclusiveMaximum = None,
    minLength = None, maxLength = None, pattern = "", enum = [],
    items = None, minItems = None, maxItems = None,
    properties = [], required = [], ref = "")
}

/// Construct a $ref schema.
@stable(since="0.1")
pub func refSchema(name: in String): Schema
  requires: name.length > 0
{
  return Schema(
    type = None, format = "", description = "", nullable = false,
    deprecated = false, minimum = None, maximum = None,
    exclusiveMinimum = None, exclusiveMaximum = None,
    minLength = None, maxLength = None, pattern = "", enum = [],
    items = None, minItems = None, maxItems = None,
    properties = [], required = [], ref = "#/components/schemas/" + name)
}

// ─── Parameters and request body ─────────────────────────────────────────────

@stable(since="0.1")
pub enum ParameterLocation {
  case Path
  case Query
  case Header
  case Cookie
}

@stable(since="0.1")
pub record Parameter {
  name:        String
  in:          ParameterLocation
  required:    Bool
  description: String
  deprecated:  Bool
  schema:      Schema
}

@stable(since="0.1")
pub record MediaType {
  contentType: String    // "application/json"
  schema:      Schema
}

@stable(since="0.1")
pub record RequestBody {
  description: String
  required:    Bool
  content:     [MediaType]
}

// ─── Responses ────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record ApiResponse {
  statusCode:  Int
  description: String
  content:     [MediaType]    // empty → no body
}

// ─── Operations ───────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Operation {
  operationId: String
  summary:     String
  description: String
  tags:        [String]
  parameters:  [Parameter]
  requestBody: Option[RequestBody]
  responses:   [ApiResponse]
  deprecated:  Bool
}

// ─── Paths ────────────────────────────────────────────────────────────────────

/// A single path item binding URL patterns to HTTP-method operations.
@stable(since="0.1")
pub record PathItem {
  pattern:    String
  get:        Option[Operation]
  post:       Option[Operation]
  put:        Option[Operation]
  delete:     Option[Operation]
  patch:      Option[Operation]
  head:       Option[Operation]
  options:    Option[Operation]
}

// ─── Spec ─────────────────────────────────────────────────────────────────────

/// Top-level OpenAPI 3.1 document.
@stable(since="0.1")
pub record Spec {
  openapi:    String           // always "3.1.0"
  info:       Info
  paths:      [PathItem]
  schemas:    [(String, Schema)] // components/schemas entries
  servers:    [String]           // server URL strings
}

/// Construct an empty spec with the given metadata.
@stable(since="0.1")
pub func newSpec(title: in String, version: in String, description: in String): Spec
  requires: title.length > 0
  requires: version.length > 0
{
  val info = Info(title = title, version = version, description = description,
                  contact = None, license = None)
  return Spec(openapi = "3.1.0", info = info, paths = [], schemas = [], servers = [])
}

/// Add a server URL to the spec.
@stable(since="0.1")
pub func addServer(spec: in Spec, url: in String): Spec {
  return Spec(openapi = spec.openapi, info = spec.info, paths = spec.paths,
              schemas = spec.schemas, servers = spec.servers + [url])
}

/// Add a reusable schema component.
@stable(since="0.1")
pub func addSchema(spec: in Spec, name: in String, schema: in Schema): Spec
  requires: name.length > 0
{
  return Spec(openapi = spec.openapi, info = spec.info, paths = spec.paths,
              schemas = spec.schemas + [(name, schema)], servers = spec.servers)
}

/// Add a path item to the spec.
@stable(since="0.1")
pub func addPath(spec: in Spec, item: in PathItem): Spec {
  return Spec(openapi = spec.openapi, info = spec.info, paths = spec.paths + [item],
              schemas = spec.schemas, servers = spec.servers)
}
