//! Domain tests — proof oracle and helper function correctness.
@test_module
package ProductCatalog.Tests.Domain

import Std.Core
import Std.Testing
import ProductCatalog.Domain

// ─── categoryToString / categoryFromString round-trip ─────────────────────────
test "categoryToString Electronics" {
  assertTrue(categoryToString(Electronics) == "electronics", "categoryToString(Electronics)")
}

test "categoryToString Clothing" {
  assertTrue(categoryToString(Clothing) == "clothing", "categoryToString(Clothing)")
}

test "categoryToString Books" {
  assertTrue(categoryToString(Books) == "books", "categoryToString(Books)")
}

test "categoryToString Food" {
  assertTrue(categoryToString(Food) == "food", "categoryToString(Food)")
}

test "categoryToString Home" {
  assertTrue(categoryToString(Home) == "home", "categoryToString(Home)")
}

test "categoryToString Sports" {
  assertTrue(categoryToString(Sports) == "sports", "categoryToString(Sports)")
}

test "categoryToString Other" {
  assertTrue(categoryToString(Other) == "other", "categoryToString(Other)")
}

test "categoryFromString round-trip electronics" {
  assertTrue(categoryToString(categoryFromString("electronics")) == "electronics", "categoryFromString round-trip")
}

test "categoryFromString round-trip clothing" {
  assertTrue(categoryToString(categoryFromString("clothing")) == "clothing", "categoryFromString round-trip")
}

test "categoryFromString unknown maps to other" {
  assertTrue(categoryToString(categoryFromString("gadgets")) == "other", "categoryFromString unknown")
}

test "categoryFromString empty maps to other" {
  assertTrue(categoryToString(categoryFromString("")) == "other", "categoryFromString empty")
}

// ─── priceDollars formatting ──────────────────────────────────────────────────
test "priceDollars zero" {
  assertTrue(priceDollars(0) == "$0.00", "priceDollars(0)")
}

test "priceDollars one cent" {
  assertTrue(priceDollars(1) == "$0.01", "priceDollars(1)")
}

test "priceDollars one dollar" {
  assertTrue(priceDollars(100) == "$1.00", "priceDollars(100)")
}

test "priceDollars $9.99" {
  assertTrue(priceDollars(999) == "$9.99", "priceDollars(999)")
}

test "priceDollars $100.00" {
  assertTrue(priceDollars(10000) == "$100.00", "priceDollars(10000)")
}

test "priceDollars $1000.50" {
  assertTrue(priceDollars(100050) == "$1000.50", "priceDollars(100050)")
}

// ─── Proof oracles ────────────────────────────────────────────────────────────
test "priceValid at zero" {
  assertTrue(priceValid(0) == true, "priceValid(0)")
}

test "priceValid at max" {
  assertTrue(priceValid(10_000_000) == true, "priceValid(10_000_000)")
}

test "priceValid mid-range" {
  assertTrue(priceValid(4999) == true, "priceValid(4999)")
}

test "nameValid single char" {
  assertTrue(nameValid("A") == true, "nameValid(A)")
}

test "nameValid at length 200 boundary" {
  var s: String = ""
  var i: Int = 0
  while i < 200 {
    s = s + "x"
    i = i + 1
  }
  assertTrue(nameValid(s) == true, "nameValid(200 chars)")
}

test "stockValid at zero" {
  assertTrue(stockValid(0) == true, "stockValid(0)")
}

test "stockValid at max" {
  assertTrue(stockValid(1_000_000) == true, "stockValid(1_000_000)")
}

test "priceEditNonNegating both zero" {
  assertTrue(priceEditNonNegating(0, 0) == true, "priceEditNonNegating(0, 0)")
}

test "priceEditNonNegating increase" {
  assertTrue(priceEditNonNegating(100, 200) == true, "priceEditNonNegating increase")
}

test "priceEditNonNegating decrease" {
  assertTrue(priceEditNonNegating(500, 100) == true, "priceEditNonNegating decrease")
}

// ─── createRequestValid oracle ────────────────────────────────────────────────
test "createRequestValid minimal" {
  val req = CreateProductRequest(name = "Widget", description = "", category = "other", priceCents = 0, stockCount = 0, inStock = false)
  assertTrue(createRequestValid(req) == true, "createRequestValid(minimal)")
}

test "createRequestValid full" {
  val req = CreateProductRequest(
    name = "Professional Laptop",
    description = "High-performance laptop for developers",
    category = "electronics",
    priceCents = 249900,
    stockCount = 50,
    inStock = true
  )
  assertTrue(createRequestValid(req) == true, "createRequestValid(full)")
}
