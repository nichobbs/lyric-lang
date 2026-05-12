// benchmarks/bench_collections.l — Std.Collections throughput benchmarks.
//
// Measures List and Map operations to surface allocation rate and GC pressure.
// Covers:
//   * List build (sequential add)
//   * List traversal (sequential count)
//   * List build + sum (allocation + read path together)
//   * Map insert + lookup (tree balance, allocation, hashing)
//
// These benchmarks intentionally allocate heavily — the intent is to show
// where GC pressure differs between --target dotnet and --target jvm.
//
// Run with: lyric bench benchmarks/bench_collections.l

@bench_module
package Bench.Collections

import Std.Core
import Std.Collections
import Std.Time

// ─── List build ───────────────────────────────────────────────────────────────

@bench
pub func benchListBuild(): Unit {
  var lst: List[Int] = newList()
  var i = 0
  while i < 10000 {
    lst.add(i)
    i = i + 1
  }
  if lst.count < 0 { println(toString(lst.count)) }
}

// ─── List traversal ───────────────────────────────────────────────────────────

func buildList(n: in Int): List[Int] {
  var lst: List[Int] = newList()
  var i = 0
  while i < n {
    lst.add(i)
    i = i + 1
  }
  lst
}

@bench
pub func benchListTraversal(): Unit {
  val lst = buildList(10000)
  var acc = 0
  var i   = 0
  while i < lst.count {
    acc = acc + lst[i]
    i   = i + 1
  }
  if acc < 0 { println(toString(acc)) }
}

// ─── List build + sum (allocation + read together) ───────────────────────────

@bench
pub func benchListBuildAndSum(): Unit {
  var lst: List[Int] = newList()
  var i = 0
  while i < 5000 {
    lst.add(i * 2)
    i = i + 1
  }
  var acc = 0
  var j   = 0
  while j < lst.count {
    acc = acc + lst[j]
    j = j + 1
  }
  if acc < 0 { println(toString(acc)) }
}

// ─── Map insert ───────────────────────────────────────────────────────────────

@bench
pub func benchMapInsert(): Unit {
  var m: Map[String, Int] = newMap()
  var i = 0
  while i < 1000 {
    m.add(toString(i), i)
    i = i + 1
  }
  if m.count < 0 { println(toString(m.count)) }
}

// ─── Map insert + lookup ──────────────────────────────────────────────────────

@bench
pub func benchMapInsertLookup(): Unit {
  var m: Map[String, Int] = newMap()
  var i = 0
  while i < 1000 {
    m.add(toString(i), i)
    i = i + 1
  }
  var found = 0
  var j = 0
  while j < 1000 {
    val key = toString(j)
    match mapGet(m, key) {
      case Some(v) -> { found = found + v }
      case None    -> {}
    }
    j = j + 1
  }
  if found < 0 { println(toString(found)) }
}
