//! ProductCatalog.Catalog — gRPC handler implementations.
//!
//! Each handler:
//!   1. Validates the request (returns INVALID_ARGUMENT on bad input).
//!   2. Opens a DB connection, executes the SQL query, closes the connection.
//!   3. Returns Ok(response) or Err(GrpcStatus) on failure.
//!
//! Auth is enforced by the GrpcAuth and GrpcCircuit aspects declared below —
//! handlers themselves are auth-agnostic.  The aspects live in this same
//! package because aspect weaving is package-local: a matching aspect only
//! weaves over functions declared alongside it (docs/26-aspects.md §3, §16).
//! They reuse the library templates from Grpc.Aspects (`pub aspect` shares
//! advice logic across packages; the weaving still happens here, §18).
//!
//! `authToken: String` is declared on every handler but intentionally unused
//! in the body; the gRPC kernel injects it from metadata and the aspects
//! validate it before the body runs.
@runtime_checked
package ProductCatalog.Catalog

import Std.Core
import Std.Collections
import Grpc
import Grpc.Aspects
import Db
import ProductCatalog.Domain

// connectionString is set via LYRIC_CONFIG_CATALOGDB_CONNECTIONSTRING (required)
config CatalogDb {
  connectionString: String
  defaultPageSize: Int = 20
  maxPageSize: Int = 100
}

// ─── Aspects ────────────────────────────────────────────────────────────────
// Bind the library templates to the handlers in this package.  Ordering
// (outermost → innermost → handler): GrpcAuth → GrpcCircuit → handler.  A
// handler that returns UNAUTHENTICATED bypasses the circuit counter because
// the request never reaches the handler body.
//
//   GrpcAuth  reads authToken from gRPC metadata (LYRIC_ASPECT_GRPCAUTH_*).
//   GrpcCircuit opens after 3 consecutive failures, cools down for 15s.
aspect GrpcAuth from Grpc.Aspects.RequiresGrpcAuth {
  matches: name in { getProduct, listProducts, createProduct, updateProduct, deleteProduct }
}

aspect GrpcCircuit from Grpc.Aspects.GrpcCircuitBreaker {
  inside: GrpcAuth
  matches: name in { getProduct, listProducts, createProduct, updateProduct, deleteProduct }
  config {
    failureThreshold: Int = 3
    cooldownMs: Int = 15000
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
func productCols(): String {
  return "id, name, description, category, price_cents, in_stock, stock_count, created_at"
}

func openDb(): Result[DbConnection, GrpcStatus] {
  match Db.connect(CatalogDb.connectionString) {
    case Err(e) -> return Err(Grpc.unavailable("Database connection unavailable: " + e.message))
    case Ok(c) -> return Ok(c)
  }
}

func rowToProduct(row: in DbRow): Product {
  return Product(
    id = Db.getLong(row, "id"),
    name = Db.getString(row, "name"),
    description = Db.getString(row, "description"),
    category = Db.getString(row, "category"),
    priceCents = Db.getInt(row, "price_cents"),
    inStock = Db.getBool(row, "in_stock"),
    stockCount = Db.getInt(row, "stock_count"),
    createdAt = Db.getString(row, "created_at")
  )
}

func dbErrToStatus(e: in DbError): GrpcStatus {
  return Grpc.internal("Database error: " + e.message)
}

func resolvePageSize(requested: in Int): Int {
  if requested <= 0 {
    return CatalogDb.defaultPageSize
  }
  if requested > CatalogDb.maxPageSize {
    return CatalogDb.maxPageSize
  }
  return requested
}

record ListQuery {
  sql: String
  params: List[String]
}

/// Build a SQL query + params for the products list, keeping both in sync.
func buildListQuery(category: in String, inStockOnly: in Bool, pageSize: in Int): ListQuery {
  val base = "SELECT " + productCols() + " FROM products"
  if category.length > 0 and inStockOnly {
    return ListQuery(
      sql = base + " WHERE category = $1 AND in_stock = true ORDER BY name LIMIT $2",
      params = [category, pageSize.toString()]
    )
  }
  if category.length > 0 {
    return ListQuery(sql = base + " WHERE category = $1 ORDER BY name LIMIT $2", params = [category, pageSize.toString()])
  }
  if inStockOnly {
    return ListQuery(sql = base + " WHERE in_stock = true ORDER BY name LIMIT $1", params = [pageSize.toString()])
  }
  return ListQuery(sql = base + " ORDER BY name LIMIT $1", params = [pageSize.toString()])
}

// ─── GetProduct ───────────────────────────────────────────────────────────────
@grpc_service("ProductCatalog.ProductService")
@rpc("GetProduct")
pub func getProduct(req: in GetProductRequest, authToken: in String): Result[Product, GrpcStatus] {
  if req.id <= 0 {
    return Err(Grpc.invalidArgument("id must be positive"))
  }
  match openDb() {
    case Err(s) -> return Err(s)
    case Ok(db) -> {
      val result = Db.queryOne(db, "SELECT " + productCols() + " FROM products WHERE id = $1", [req.id.toString()])
      db.close()
      match result {
        case Err(e) -> return Err(dbErrToStatus(e))
        case Ok(None) -> return Err(Grpc.notFound("Product " + req.id.toString() + " not found"))
        case Ok(Some(row)) -> return Ok(rowToProduct(row))
      }
    }
  }
}

// ─── ListProducts ─────────────────────────────────────────────────────────────
@grpc_service("ProductCatalog.ProductService")
@rpc("ListProducts")
pub func listProducts(req: in ListProductsRequest, authToken: in String): Result[ListProductsResponse, GrpcStatus] {
  val pageSize = resolvePageSize(req.pageSize)
  match openDb() {
    case Err(s) -> return Err(s)
    case Ok(db) -> {
      val q = buildListQuery(req.category, req.inStockOnly, pageSize)
      val result = Db.query(db, q.sql, q.params)
      db.close()
      match result {
        case Err(e) -> return Err(dbErrToStatus(e))
        case Ok(rows) -> {
          var products: List[Product] = []
          for row in rows {
            products = products + [rowToProduct(row)]
          }
          return Ok(ListProductsResponse(products = products, total = products.count))
        }
      }
    }
  }
}

// ─── CreateProduct ────────────────────────────────────────────────────────────
@grpc_service("ProductCatalog.ProductService")
@rpc("CreateProduct")
pub func createProduct(req: in CreateProductRequest, authToken: in String): Result[Product, GrpcStatus] {
  if req.name.length == 0 {
    return Err(Grpc.invalidArgument("name is required"))
  }
  if req.name.length > 200 {
    return Err(Grpc.invalidArgument("name must be 200 characters or fewer"))
  }
  if req.priceCents < 0 {
    return Err(Grpc.invalidArgument("priceCents must be non-negative"))
  }
  if req.priceCents > 10_000_000 {
    return Err(Grpc.invalidArgument("priceCents exceeds maximum ($100,000.00)"))
  }
  if req.stockCount < 0 {
    return Err(Grpc.invalidArgument("stockCount must be non-negative"))
  }
  if req.stockCount > 1_000_000 {
    return Err(Grpc.invalidArgument("stockCount exceeds maximum"))
  }
  val category = ProductCatalog.Domain.categoryToString(ProductCatalog.Domain.categoryFromString(req.category))
  match openDb() {
    case Err(s) -> return Err(s)
    case Ok(db) -> {
      val result = Db.queryOne(
        db,
        "INSERT INTO products (name, description, category, price_cents, in_stock, stock_count, created_at) VALUES ($1, $2, $3, $4, $5, $6, NOW()) RETURNING " +
          productCols(),
        [
          req.name,
          req.description,
          category,
          req.priceCents.toString(),
          req.inStock.toString(),
          req.stockCount.toString()
        ]
      )
      db.close()
      match result {
        case Err(e) -> return Err(dbErrToStatus(e))
        case Ok(None) -> return Err(Grpc.internal("Insert returned no rows"))
        case Ok(Some(row)) -> return Ok(rowToProduct(row))
      }
    }
  }
}

// ─── UpdateProduct ────────────────────────────────────────────────────────────
@grpc_service("ProductCatalog.ProductService")
@rpc("UpdateProduct")
pub func updateProduct(req: in UpdateProductRequest, authToken: in String): Result[Product, GrpcStatus] {
  if req.id <= 0 {
    return Err(Grpc.invalidArgument("id must be positive"))
  }
  if req.priceCents < 0 {
    return Err(Grpc.invalidArgument("priceCents must be non-negative"))
  }
  if req.priceCents > 10_000_000 {
    return Err(Grpc.invalidArgument("priceCents exceeds maximum ($100,000.00)"))
  }
  if req.stockCount < 0 {
    return Err(Grpc.invalidArgument("stockCount must be non-negative"))
  }
  match openDb() {
    case Err(s) -> return Err(s)
    case Ok(db) -> {
      val result = Db.queryOne(
        db,
        "UPDATE products SET price_cents = $1, in_stock = $2, stock_count = $3 WHERE id = $4 RETURNING " +
          productCols(),
        [req.priceCents.toString(), req.inStock.toString(), req.stockCount.toString(), req.id.toString()]
      )
      db.close()
      match result {
        case Err(e) -> return Err(dbErrToStatus(e))
        case Ok(None) -> return Err(Grpc.notFound("Product " + req.id.toString() + " not found"))
        case Ok(Some(row)) -> return Ok(rowToProduct(row))
      }
    }
  }
}

// ─── DeleteProduct ────────────────────────────────────────────────────────────
@grpc_service("ProductCatalog.ProductService")
@rpc("DeleteProduct")
pub func deleteProduct(req: in DeleteProductRequest, authToken: in String): Result[DeleteProductResponse, GrpcStatus] {
  if req.id <= 0 {
    return Err(Grpc.invalidArgument("id must be positive"))
  }
  match openDb() {
    case Err(s) -> return Err(s)
    case Ok(db) -> {
      val result = Db.execute(db, "DELETE FROM products WHERE id = $1", [req.id.toString()])
      db.close()
      match result {
        case Err(e) -> return Err(dbErrToStatus(e))
        case Ok(deleted) -> return Ok(DeleteProductResponse(deleted = deleted > 0))
      }
    }
  }
}
