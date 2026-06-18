/// Domain tests — proof oracle and helper function correctness.

@test_module
package ProductCatalog.Tests.Domain

import Std.Core
import Std.Testing
import ProductCatalog.Domain

// ─── categoryToString / categoryFromString round-trip ─────────────────────────

test "categoryToString Electronics" {
  assert categoryToString(Electronics) == "electronics"
}

test "categoryToString Clothing" {
  assert categoryToString(Clothing) == "clothing"
}

test "categoryToString Books" {
  assert categoryToString(Books) == "books"
}

test "categoryToString Food" {
  assert categoryToString(Food) == "food"
}

test "categoryToString Home" {
  assert categoryToString(Home) == "home"
}

test "categoryToString Sports" {
  assert categoryToString(Sports) == "sports"
}

test "categoryToString Other" {
  assert categoryToString(Other) == "other"
}

test "categoryFromString round-trip electronics" {
  assert categoryToString(categoryFromString("electronics")) == "electronics"
}

test "categoryFromString round-trip clothing" {
  assert categoryToString(categoryFromString("clothing")) == "clothing"
}

test "categoryFromString unknown maps to other" {
  assert categoryToString(categoryFromString("gadgets")) == "other"
}

test "categoryFromString empty maps to other" {
  assert categoryToString(categoryFromString("")) == "other"
}

// ─── priceDollars formatting ──────────────────────────────────────────────────

test "priceDollars zero" {
  assert priceDollars(0) == "$0.00"
}

test "priceDollars one cent" {
  assert priceDollars(1) == "$0.01"
}

test "priceDollars one dollar" {
  assert priceDollars(100) == "$1.00"
}

test "priceDollars $9.99" {
  assert priceDollars(999) == "$9.99"
}

test "priceDollars $100.00" {
  assert priceDollars(10000) == "$100.00"
}

test "priceDollars $1000.50" {
  assert priceDollars(100050) == "$1000.50"
}

// ─── Proof oracles ────────────────────────────────────────────────────────────

test "priceValid at zero" {
  assert priceValid(0) == true
}

test "priceValid at max" {
  assert priceValid(10_000_000) == true
}

test "priceValid mid-range" {
  assert priceValid(4999) == true
}

test "nameValid single char" {
  assert nameValid("A") == true
}

test "nameValid at length 200 boundary" {
  var s: String = ""
  var i: Int = 0
  while i < 200 { s = s + "x"; i = i + 1 }
  assert nameValid(s) == true
}

test "stockValid at zero" {
  assert stockValid(0) == true
}

test "stockValid at max" {
  assert stockValid(1_000_000) == true
}

test "priceEditNonNegating both zero" {
  assert priceEditNonNegating(0, 0) == true
}

test "priceEditNonNegating increase" {
  assert priceEditNonNegating(100, 200) == true
}

test "priceEditNonNegating decrease" {
  assert priceEditNonNegating(500, 100) == true
}

// ─── createRequestValid oracle ────────────────────────────────────────────────

test "createRequestValid minimal" {
  val req = CreateProductRequest(
    name        = "Widget",
    description = "",
    category    = "other",
    priceCents  = 0,
    stockCount  = 0
  )
  assert createRequestValid(req) == true
}

test "createRequestValid full" {
  val req = CreateProductRequest(
    name        = "Professional Laptop",
    description = "High-performance laptop for developers",
    category    = "electronics",
    priceCents  = 249900,
    stockCount  = 50
  )
  assert createRequestValid(req) == true
}
