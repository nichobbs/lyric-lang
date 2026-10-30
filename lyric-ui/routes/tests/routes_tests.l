//! tests/routes_tests.l — unit tests for the Ui.Routes generator.  The
//! generated code itself is compiled and run by examples/ui-customers, whose
//! routes are derived with it.
@test_module
package Ui.RoutesTests

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.GeneratorSdk
import Ui.Routes

// An `Option[inner]` case field; it is a query field only if the case says so
// with `@query(name)`.
func queryField(name: in String, inner: in String): FieldDescriptor {
  FieldDescriptor(
    name = name,
    fieldType = FieldType(kind = OptionType, name = "Option[" + inner + "]", typeArgs = [inner]),
    isPublic = true,
    annotations = []
  )
}

func query(args: in slice[String]): AnnotationDescriptor {
  AnnotationDescriptor(name = "query", args = args)
}

func queryCase(
  name: in String,
  path: in String,
  fields: in slice[FieldDescriptor],
  queries: in slice[AnnotationDescriptor],
): CaseDescriptor {
  val anns: List[AnnotationDescriptor] = newList()
  anns.add(AnnotationDescriptor(name = "path", args = ["\"" + path + "\""]))
  var i = 0
  while i < queries.length {
    anns.add(queries[i])
    i += 1
  }
  CaseDescriptor(name = name, annotations = anns.toArray(), fields = fields)
}

func named(name: in String, ty: in String): FieldDescriptor {
  FieldDescriptor(
    name = name,
    fieldType = FieldType(kind = Named, name = ty, typeArgs = []),
    isPublic = true,
    annotations = []
  )
}

func routeCase(name: in String, path: in String, fields: in slice[FieldDescriptor]): CaseDescriptor {
  CaseDescriptor(
    name = name,
    annotations = [AnnotationDescriptor(name = "path", args = ["\"" + path + "\""])],
    fields = fields
  )
}

func request(cases: in slice[CaseDescriptor], decls: in slice[DeclarationDescriptor]): GeneratorRequest {
  val td = TypeDescriptor(
    kind = Union,
    name = "Route",
    packageName = "App",
    typeParams = [],
    fields = [],
    annotations = [],
    cases = cases
  )
  GeneratorRequest(
    generatorArg = "Ui.Routes",
    typeDescriptor = td,
    packageName = "App",
    sourceFile = "r.l",
    declarations = decls
  )
}

func idDecl(): DeclarationDescriptor {
  DeclarationDescriptor(
    name = "CustomerId",
    kind = DeclaredDistinct,
    underlying = Some(value = "Long"),
    range = Some(value = RangeDescriptor(min = Some(value = "1"), max = Some(value = "9_999_999"), maxInclusive = true)),
    cases = []
  )
}

func codes(r: in GeneratorResponse): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < r.diagnostics.length {
    match r.diagnostics[i].code {
      case Some(c) -> acc.add(c)
      case None -> ()
    }
    i += 1
  }
  acc
}

test "parseRoute and routeUrl for literal and field segments" {
  val r = generateSource(
    request(
      [
        routeCase("CustomerList", "/customers", []),
        routeCase("NewCustomer", "/customers/new", []),
        routeCase("EditCustomer", "/customers/{id}", [named("id", "CustomerId")])
      ],
      [idDecl()]
    )
  )
  assertEqualInt(r.diagnostics.length, 0, "no diagnostics")
  val src = r.lyricSource
  assertTrue(src.contains("pub func parseRoute(url: in String): Option[Route] {"), "parse: " + src)
  assertTrue(
    src.contains("  match parseRouteCustomerList(segments, url) {\n    case Some(r) -> return Some(value = r)"),
    "cases tried in order"
  )
  assertTrue(src.contains("  if segments[1] != \"new\" {\n    return None\n  }"), "literal segment")
  assertTrue(
    src.contains(
      "return match routeEditCustomerIdSegment(segments[1]) {\n    case Some(id) -> Some(value = Route.EditCustomer(id = id))"
    ),
    "field segment"
  )
  assertTrue(src.contains("match CustomerId.tryFrom(n) {"), "a range type rejects values outside it")
  assertTrue(src.contains("pub func routeUrl(r: in Route): String {"), "url")
  assertTrue(
    src.contains("case EditCustomer(id) -> \"/customers\" + \"/\" + GenRouting.encodeSegment(id.toString())"),
    "url of a field"
  )
  assertTrue(src.contains("case CustomerList -> \"/customers\""), "url of a literal path")
  assertEqual(r.additionalImports[2], "import Ui.Routing as GenRouting", "import")
}

test "the root path and an enum segment" {
  val sort = DeclarationDescriptor(
    name = "Sort",
    kind = DeclaredEnum,
    underlying = None,
    range = None,
    cases = [
      CaseDescriptor(name = "ByName", annotations = [], fields = []),
      CaseDescriptor(name = "ByLimit", annotations = [], fields = [])
    ]
  )
  val r = generateSource(
    request([routeCase("Home", "/", []), routeCase("Sorted", "/list/{by}", [named("by", "Sort")])], [sort])
  )
  assertEqualInt(r.diagnostics.length, 0, "no diagnostics")
  assertTrue(r.lyricSource.contains("case Home -> \"/\""), "the root")
  assertTrue(
    r.lyricSource.contains("if text == \"ByName\" {\n    Some(value = Sort.ByName)\n  } else if"),
    "enum by case name"
  )
  assertTrue(r.lyricSource.contains("GenRouting.encodeSegment(routeSortedByText(by))"), "enum text")
}

test "path problems are reported" {
  assertTrue(
    codes(generateSource(request([CaseDescriptor(name = "A", annotations = [], fields = [])], []))).contains("RT002"),
    "no @path"
  )
  assertTrue(
    codes(generateSource(request([routeCase("A", "customers", [])], []))).contains("RT002"),
    "no leading slash"
  )
  assertTrue(codes(generateSource(request([routeCase("A", "/a b", [])], []))).contains("RT002"), "a space in a literal")
  assertTrue(codes(generateSource(request([routeCase("A", "/a/{x}", [])], []))).contains("RT003"), "an unknown field")
  assertTrue(
    codes(generateSource(request([routeCase("A", "/a", [named("x", "String")])], []))).contains("RT003"),
    "a field not in the path"
  )
  assertTrue(
    codes(generateSource(request([routeCase("A", "/a/{x}/{x}", [named("x", "String")])], []))).contains("RT003"),
    "a field twice"
  )
  assertTrue(
    codes(generateSource(request([routeCase("A", "/a/{x}", [named("x", "Money")])], []))).contains("RT004"),
    "an unsupported type"
  )
  assertTrue(
    codes(generateSource(request([routeCase("A", "/a/{x}", [named("x", "String")]), routeCase("B", "/a/{y}", [named("y", "Int")])], []))).contains(
      "RT005"
    ),
    "two cases with one shape"
  )
}

test "a record is not a route union" {
  val td = TypeDescriptor(kind = Record, name = "R", packageName = "P", typeParams = [], fields = [], annotations = [])
  val r = generateSource(
    GeneratorRequest(generatorArg = "Ui.Routes", typeDescriptor = td, packageName = "P", sourceFile = "p.l")
  )
  assertTrue(codes(r).contains("RT001"), "RT001")
  assertEqual(r.lyricSource, "", "no code")
}

test "a segment type names how to read a field declared elsewhere" {
  val r = generateSource(request([routeCase("EditCustomer", "/customers/{id:Long}", [named("id", "CustomerId")])], []))
  assertEqualInt(r.diagnostics.length, 0, "no diagnostics")
  assertTrue(
    r.lyricSource.contains("match GenRouting.longSegment(text) {\n    case Some(n) -> match CustomerId.tryFrom(n) {"),
    "parsed and converted"
  )
  assertTrue(r.lyricSource.contains("GenRouting.encodeSegment(id.toString())"), "written as its text")
  assertTrue(
    codes(generateSource(request([routeCase("A", "/a/{x:Money}", [named("x", "Money")])], []))).contains("RT002"),
    "an unknown segment type"
  )
  val unknown = generateSource(request([routeCase("A", "/a/{x}", [named("x", "Money")])], []))
  assertTrue(unknown.diagnostics[0].message.contains("{x:Long}"), "the RT004 message suggests a segment type")
}

test "a @query field is read from the query and written after the path" {
  val sort = DeclarationDescriptor(
    name = "Sort",
    kind = DeclaredEnum,
    underlying = None,
    range = None,
    cases = [
      CaseDescriptor(name = "ByName", annotations = [], fields = []),
      CaseDescriptor(name = "ByLimit", annotations = [], fields = [])
    ]
  )
  val r = generateSource(
    request(
      [
        queryCase(
          "Search",
          "/search/{scope}",
          [
            named("scope", "String"),
            queryField("term", "String"),
            queryField("page", "Int"),
            queryField("sort", "Sort")
          ],
          [query(["term"]), query(["page", "\"p\""]), query(["sort"])]
        )
      ],
      [sort]
    )
  )
  assertEqualInt(r.diagnostics.length, 0, "no diagnostics")
  val src = r.lyricSource
  assertTrue(
    src.contains("func parseRouteSearch(segments: in List[String], url: in String): Option[Route] {"),
    "url reaches the case: " + src
  )
  assertTrue(
    src.contains("match routeSearchTermQuery(url) {\n    case Some(term) ->"),
    "query field bound from the url"
  )
  assertTrue(src.contains("GenRouting.queryPresent(url, \"term\")"), "the parameter defaults to the field name")
  assertTrue(src.contains("GenRouting.queryPresent(url, \"p\")"), "@query(page, \"p\") renames the parameter")
  assertTrue(src.contains("val absent: Option[String] = None"), "absent is None")
  assertTrue(
    src.contains("func routeSearchPageQuery(url: in String): Option[Option[Int]] {"),
    "a failed parse rejects the case"
  )
  assertFalse(src.contains("GenRouting.longSegment(text)"), "Int uses intSegment")
  assertTrue(src.contains("GenRouting.intSegment(text)"), "Int parse")
  assertTrue(src.contains("func routeSearchSortQueryText(v: in Option[Sort]): Option[String] {"), "enum text helper")
  assertTrue(src.contains("routeSearchSortText(inner)"), "enum text")
  assertTrue(
    src.contains(
      "case Search(scope, term, page, sort) -> GenRouting.withQuery(GenRouting.withQuery(GenRouting.withQuery(\"/search\" + \"/\" + GenRouting.encodeSegment(scope), \"term\", routeSearchTermQueryText(term)), \"p\", routeSearchPageQueryText(page)), \"sort\", routeSearchSortQueryText(sort))"
    ),
    "url appends the query in field order"
  )
}

test "@query problems are reported" {
  val plain = [named("x", "String")]
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String")], [query(["y"])])], []))).contains(
      "RT007"
    ),
    "names no field"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", plain, [query(["x"])])], []))).contains("RT007"),
    "not an Option"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "Money")], [query(["x"])])], []))).contains(
      "RT004"
    ),
    "an unsupported value type"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a/{x}", [queryField("x", "String")], [query(["x"])])], []))).contains(
      "RT007"
    ),
    "a query field in the path"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String"), queryField("y", "String")], [query(["x"]), query(["y", "\"x\""])])], []))).contains(
      "RT007"
    ),
    "two fields on one parameter"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String")], [query(["x"]), query(["x"])])], []))).contains(
      "RT007"
    ),
    "one field marked twice"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String")], [query([])])], []))).contains(
      "RT007"
    ),
    "no field named"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String")], [query(["x", "\"\""])])], []))).contains(
      "RT007"
    ),
    "an empty parameter name"
  )
  assertTrue(
    codes(generateSource(request([queryCase("A", "/a", [queryField("x", "String")], [query(["x", "name"])])], []))).contains(
      "RT007"
    ),
    "a parameter name that is not a literal"
  )
}
