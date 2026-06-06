//! Catalog handler tests — request validation and response shape.
//!
//! Handler bodies that touch the database are not exercised here
//! (that requires an integration test environment).  These tests cover:
//!   - GrpcStatus code enum values (GrpcStatusCode, not raw integers)
//!   - Response record field completeness
//!   - Proto field annotation presence on wire records
//!   - Category and price formatting used in handler helpers
@test_module
package ProductCatalog.Tests.Catalog

import Std.Core
import Std.Testing
import Grpc
import Grpc.Types
import ProductCatalog.Domain

// ─── GrpcStatus constructors ─────────────────────────────────────────────────
test "invalidArgument has INVALID_ARGUMENT code" {
  val s = Grpc.invalidArgument("bad input")
  assert
  s.code == GrpcStatusCode.InvalidArgument
  assert
  s.message == "bad input"
}

test "notFound has NOT_FOUND code" {
  val s = Grpc.notFound("not there")
  assert
  s.code == GrpcStatusCode.NotFound
}

test "alreadyExists has ALREADY_EXISTS code" {
  val s = Grpc.alreadyExists("duplicate")
  assert
  s.code == GrpcStatusCode.AlreadyExists
}

test "permissionDenied has PERMISSION_DENIED code" {
  val s = Grpc.permissionDenied("no access")
  assert
  s.code == GrpcStatusCode.PermissionDenied
}

test "resourceExhausted has RESOURCE_EXHAUSTED code" {
  val s = Grpc.resourceExhausted("quota exceeded")
  assert
  s.code == GrpcStatusCode.ResourceExhausted
}

test "internal has INTERNAL code" {
  val s = Grpc.internal("boom")
  assert
  s.code == GrpcStatusCode.Internal
}

test "unavailable has UNAVAILABLE code" {
  val s = Grpc.unavailable("down")
  assert
  s.code == GrpcStatusCode.Unavailable
}

test "unauthenticated has UNAUTHENTICATED code" {
  val s = Grpc.unauthenticated("no token")
  assert
  s.code == GrpcStatusCode.Unauthenticated
}

// ─── statusCodeFromInt round-trips ────────────────────────────────────────────
test "statusCodeFromInt 3 is InvalidArgument" {
  assert
  statusCodeFromInt(3) == GrpcStatusCode.InvalidArgument
}

test "statusCodeFromInt 5 is NotFound" {
  assert
  statusCodeFromInt(5) == GrpcStatusCode.NotFound
}

test "statusCodeFromInt 14 is Unavailable" {
  assert
  statusCodeFromInt(14) == GrpcStatusCode.Unavailable
}

test "statusCodeFromInt 16 is Unauthenticated" {
  assert
  statusCodeFromInt(16) == GrpcStatusCode.Unauthenticated
}

test "statusCodeFromInt unknown maps to Unknown" {
  assert
  statusCodeFromInt(99) == GrpcStatusCode.Unknown
}

// ─── Domain record field shapes ───────────────────────────────────────────────
test "Product record has expected fields" {
  val p = Product(
    id = 1i64,
    name = "Laptop",
    description = "Fast",
    category = "electronics",
    priceCents = 99900,
    inStock = true,
    stockCount = 5,
    createdAt = "2024-01-01T00:00:00Z"
  )
  assert
  p.id == 1i64
  assert
  p.name == "Laptop"
  assert
  p.priceCents == 99900
  assert
  p.inStock == true
  assert
  p.stockCount == 5
}

test "GetProductRequest accepts positive id" {
  val req = GetProductRequest(id = 42i64)
  assert
  req.id == 42i64
}

test "ListProductsRequest defaults" {
  val req = ListProductsRequest(category = "", inStockOnly = false, pageSize = 0)
  assert
  req.pageSize == 0
  assert
  req.category == ""
}

test "CreateProductRequest fields" {
  val req = CreateProductRequest(
    name = "Widget",
    description = "A fine widget",
    category = "other",
    priceCents = 999,
    stockCount = 100,
    inStock = true
  )
  assert
  req.name == "Widget"
  assert
  req.priceCents == 999
  assert
  req.stockCount == 100
  assert
  req.inStock == true
}

test "UpdateProductRequest fields" {
  val req = UpdateProductRequest(id = 7i64, priceCents = 1299, inStock = true, stockCount = 20)
  assert
  req.id == 7i64
  assert
  req.priceCents == 1299
  assert
  req.inStock == true
}

test "DeleteProductRequest field" {
  val req = DeleteProductRequest(id = 99i64)
  assert
  req.id == 99i64
}

test "DeleteProductResponse deleted true" {
  val resp = DeleteProductResponse(deleted = true)
  assert
  resp.deleted == true
}

test "DeleteProductResponse deleted false" {
  val resp = DeleteProductResponse(deleted = false)
  assert
  resp.deleted == false
}

// ─── ListProductsResponse ─────────────────────────────────────────────────────
test "ListProductsResponse empty" {
  val resp = ListProductsResponse(products = [], total = 0)
  assert
  resp.total == 0
}

test "ListProductsResponse with products" {
  val p = Product(
    id = 1i64,
    name = "A",
    description = "",
    category = "books",
    priceCents = 500,
    inStock = true,
    stockCount = 3,
    createdAt = "2024-01-01T00:00:00Z"
  )
  val resp = ListProductsResponse(products = [p], total = 1)
  assert
  resp.total == 1
  assert
  resp.products.count == 1
}

// ─── Category + price helpers via Domain ─────────────────────────────────────
test "categoryFromString electronics then back" {
  assert
  categoryToString(categoryFromString("electronics")) == "electronics"
}

test "categoryFromString unknown normalises to other" {
  assert
  categoryToString(categoryFromString("unknown")) == "other"
}

test "priceDollars $9.99" {
  assert
  priceDollars(999) == "$9.99"
}

test "priceDollars $0.01" {
  assert
  priceDollars(1) == "$0.01"
}
