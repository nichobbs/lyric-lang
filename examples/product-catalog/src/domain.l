/// ProductCatalog.Domain — proof-verified domain types and invariants.
///
/// Proof oracles establish the business rules that catalog handlers enforce:
///   - prices are non-negative and within a plausible bound
///   - product names are non-empty and within display length
///   - stock quantities are non-negative
///   - price edits cannot silently flip sign
///
/// Message records carry @proto_field annotations so `lyric grpc spec`
/// (planned) can emit stable field numbers into product_catalog.proto.
/// The lock file (lyric-grpc.lock) persists assignments across runs.

@proof_required
package ProductCatalog.Domain

import Std.Core

// ─── Distinct types ───────────────────────────────────────────────────────────

pub type ProductId   = Long
pub type PriceCents  = Int range 0 ..= 10_000_000    // up to $100,000.00
pub type StockCount  = Int range 0 ..= 1_000_000

// ─── Category enum ────────────────────────────────────────────────────────────

pub enum Category {
  Electronics
  Clothing
  Books
  Food
  Home
  Sports
  Other
}

// ─── Wire records (Lyric → proto field mapping) ───────────────────────────────

/// Core product type; maps to the proto `Product` message.
pub record Product {
  @proto_field(1) id:          Long
  @proto_field(2) name:        String
  @proto_field(3) description: String
  @proto_field(4) category:    String    // categoryToString(Category)
  @proto_field(5) priceCents:  Int
  @proto_field(6) inStock:     Bool
  @proto_field(7) stockCount:  Int
  @proto_field(8) createdAt:   String    // ISO-8601
}

pub record GetProductRequest {
  @proto_field(1) id: Long
}

pub record ListProductsRequest {
  @proto_field(1) category:    String   // empty = all categories
  @proto_field(2) inStockOnly: Bool
  @proto_field(3) pageSize:    Int      // 0 = server default (20)
  // @proto_field(4) pageToken reserved — keyset pagination deferred (Q-G-003)
}

pub record ListProductsResponse {
  @proto_field(1) products: [Product]
  @proto_field(2) total:    Int          // count of returned items
  // @proto_field(3) nextPageToken reserved — keyset pagination deferred (Q-G-003)
}

pub record CreateProductRequest {
  @proto_field(1) name:        String
  @proto_field(2) description: String
  @proto_field(3) category:    String
  @proto_field(4) priceCents:  Int
  @proto_field(5) stockCount:  Int
  @proto_field(6) inStock:     Bool
}

pub record UpdateProductRequest {
  @proto_field(1) id:          Long
  @proto_field(2) priceCents:  Int
  @proto_field(3) inStock:     Bool
  @proto_field(4) stockCount:  Int
}

pub record DeleteProductRequest {
  @proto_field(1) id: Long
}

pub record DeleteProductResponse {
  @proto_field(1) deleted: Bool
}

// ─── Category helpers ─────────────────────────────────────────────────────────

pub func categoryToString(c: in Category): String
  ensures: result.length > 0
{
  match c {
    case Electronics -> return "electronics"
    case Clothing    -> return "clothing"
    case Books       -> return "books"
    case Food        -> return "food"
    case Home        -> return "home"
    case Sports      -> return "sports"
    case Other       -> return "other"
  }
}

pub func categoryFromString(s: in String): Category {
  if s == "electronics" { return Electronics }
  if s == "clothing"    { return Clothing }
  if s == "books"       { return Books }
  if s == "food"        { return Food }
  if s == "home"        { return Home }
  if s == "sports"      { return Sports }
  return Other
}

// ─── Price helpers ────────────────────────────────────────────────────────────

pub func priceDollars(priceCents: in Int): String
  requires: priceCents >= 0
  ensures:  result.length > 0
{
  val dollars   = priceCents / 100
  val cents     = priceCents - dollars * 100
  val centsStr  = if cents < 10 then "0" + cents.toString() else cents.toString()
  return "$" + dollars.toString() + "." + centsStr
}

// ─── Proof oracles ────────────────────────────────────────────────────────────

/// Price is within the supported range.
pub func priceValid(priceCents: in Int): Bool
  requires: priceCents >= 0
  requires: priceCents <= 10_000_000
  ensures:  result == true
{
  return true
}

/// Product name meets display constraints.
pub func nameValid(name: in String): Bool
  requires: name.length > 0
  requires: name.length <= 200
  ensures:  result == true
{
  return true
}

/// Stock count is non-negative.
pub func stockValid(stockCount: in Int): Bool
  requires: stockCount >= 0
  requires: stockCount <= 1_000_000
  ensures:  result == true
{
  return true
}

/// Both prices in a price-edit transaction are non-negative.
pub func priceEditNonNegating(oldCents: in Int, newCents: in Int): Bool
  requires: oldCents >= 0
  requires: newCents >= 0
  ensures:  result == true
{
  return true
}

/// Create request satisfies all domain constraints.
pub func createRequestValid(req: in CreateProductRequest): Bool
  requires: req.name.length > 0
  requires: req.name.length <= 200
  requires: req.priceCents >= 0
  requires: req.priceCents <= 10_000_000
  requires: req.stockCount >= 0
  requires: req.stockCount <= 1_000_000
  ensures:  result == true
{
  return true
}
