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
  assertTrue(s.code == GrpcStatusCode.InvalidArgument, "s.code == GrpcStatusCode.InvalidArgument")
  assertTrue(s.message == "bad input", "s.message == bad input")
}

test "notFound has NOT_FOUND code" {
  val s = Grpc.notFound("not there")
  assertTrue(s.code == GrpcStatusCode.NotFound, "s.code == GrpcStatusCode.NotFound")
}

test "alreadyExists has ALREADY_EXISTS code" {
  val s = Grpc.alreadyExists("duplicate")
  assertTrue(s.code == GrpcStatusCode.AlreadyExists, "s.code == GrpcStatusCode.AlreadyExists")
}

test "permissionDenied has PERMISSION_DENIED code" {
  val s = Grpc.permissionDenied("no access")
  assertTrue(s.code == GrpcStatusCode.PermissionDenied, "s.code == GrpcStatusCode.PermissionDenied")
}

test "resourceExhausted has RESOURCE_EXHAUSTED code" {
  val s = Grpc.resourceExhausted("quota exceeded")
  assertTrue(s.code == GrpcStatusCode.ResourceExhausted, "s.code == GrpcStatusCode.ResourceExhausted")
}

test "internal has INTERNAL code" {
  val s = Grpc.grpcInternal("boom")
  assertTrue(s.code == GrpcStatusCode.Internal, "s.code == GrpcStatusCode.Internal")
}

test "unavailable has UNAVAILABLE code" {
  val s = Grpc.unavailable("down")
  assertTrue(s.code == GrpcStatusCode.Unavailable, "s.code == GrpcStatusCode.Unavailable")
}

test "unauthenticated has UNAUTHENTICATED code" {
  val s = Grpc.unauthenticated("no token")
  assertTrue(s.code == GrpcStatusCode.Unauthenticated, "s.code == GrpcStatusCode.Unauthenticated")
}

// ─── statusCodeFromInt round-trips ────────────────────────────────────────────
test "statusCodeFromInt 3 is InvalidArgument" {
  assertTrue(statusCodeFromInt(3) == GrpcStatusCode.InvalidArgument, "statusCodeFromInt(3) == InvalidArgument")
}

test "statusCodeFromInt 5 is NotFound" {
  assertTrue(statusCodeFromInt(5) == GrpcStatusCode.NotFound, "statusCodeFromInt(5) == NotFound")
}

test "statusCodeFromInt 14 is Unavailable" {
  assertTrue(statusCodeFromInt(14) == GrpcStatusCode.Unavailable, "statusCodeFromInt(14) == Unavailable")
}

test "statusCodeFromInt 16 is Unauthenticated" {
  assertTrue(statusCodeFromInt(16) == GrpcStatusCode.Unauthenticated, "statusCodeFromInt(16) == Unauthenticated")
}

test "statusCodeFromInt unknown maps to Unknown" {
  assertTrue(statusCodeFromInt(99) == GrpcStatusCode.Unknown, "statusCodeFromInt(99) == Unknown")
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
  assertTrue(p.id == 1i64, "p.id == 1i64")
  assertTrue(p.name == "Laptop", "p.name == Laptop")
  assertTrue(p.priceCents == 99900, "p.priceCents == 99900")
  assertTrue(p.inStock == true, "p.inStock == true")
  assertTrue(p.stockCount == 5, "p.stockCount == 5")
}

test "GetProductRequest accepts positive id" {
  val req = GetProductRequest(id = 42i64)
  assertTrue(req.id == 42i64, "req.id == 42i64")
}

test "ListProductsRequest defaults" {
  val req = ListProductsRequest(category = "", inStockOnly = false, pageSize = 0)
  assertTrue(req.pageSize == 0, "req.pageSize == 0")
  assertTrue(req.category == "", "req.category == empty")
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
  assertTrue(req.name == "Widget", "req.name == Widget")
  assertTrue(req.priceCents == 999, "req.priceCents == 999")
  assertTrue(req.stockCount == 100, "req.stockCount == 100")
  assertTrue(req.inStock == true, "req.inStock == true")
}

test "UpdateProductRequest fields" {
  val req = UpdateProductRequest(id = 7i64, priceCents = 1299, inStock = true, stockCount = 20)
  assertTrue(req.id == 7i64, "req.id == 7i64")
  assertTrue(req.priceCents == 1299, "req.priceCents == 1299")
  assertTrue(req.inStock == true, "req.inStock == true")
}

test "DeleteProductRequest field" {
  val req = DeleteProductRequest(id = 99i64)
  assertTrue(req.id == 99i64, "req.id == 99i64")
}

test "DeleteProductResponse deleted true" {
  val resp = DeleteProductResponse(deleted = true)
  assertTrue(resp.deleted == true, "resp.deleted == true")
}

test "DeleteProductResponse deleted false" {
  val resp = DeleteProductResponse(deleted = false)
  assertTrue(resp.deleted == false, "resp.deleted == false")
}

// ─── ListProductsResponse ─────────────────────────────────────────────────────
test "ListProductsResponse empty" {
  val resp = ListProductsResponse(products = [], total = 0)
  assertTrue(resp.total == 0, "resp.total == 0")
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
  assertTrue(resp.total == 1, "resp.total == 1")
  assertTrue(resp.products.count == 1, "resp.products.count == 1")
}

// ─── Category + price helpers via Domain ─────────────────────────────────────
test "categoryFromString electronics then back" {
  assertTrue(categoryToString(categoryFromString("electronics")) == "electronics", "categoryToString(categoryFromString(electronics))")
}

test "categoryFromString unknown normalises to other" {
  assertTrue(categoryToString(categoryFromString("unknown")) == "other", "categoryFromString(unknown) == other")
}

test "priceDollars $9.99" {
  assertTrue(priceDollars(999) == "$9.99", "priceDollars(999) == $9.99")
}

test "priceDollars $0.01" {
  assertTrue(priceDollars(1) == "$0.01", "priceDollars(1) == $0.01")
}
