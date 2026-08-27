//! multi_impl_iface_result_self_test.l — regression coverage for issue #5133's
//! "broad" bug: adding SEVERAL `impl Interface for Record` blocks to one file
//! (same package), where at least one interface method returns ANOTHER
//! interface type wrapped in `Result`/`Option`, was suspected of a scale-
//! sensitive MethodDef/FieldDef "predicted row" bookkeeping drift in
//! `lyric-compiler/msil/lowering.l` / `codegen.l` — corruption reported as
//! widespread `InvalidProgramException`/`MissingMethodException` at runtime,
//! including on unrelated pre-existing mock methods, once a file accumulated
//! five `impl` blocks (see docs/57 §5.3, docs/03-decision-log.md D-progress-808).
//!
//! #5133's own bisection separately confirmed and fixed a NARROWER bug: an
//! interface-typed value flowing through a `Result`/`Option`-unwrapping
//! `match` (cross-package), then dispatched through a further interface
//! method call, failed to resolve the interface method's token
//! (`MissingMethodException`). That fix is exercised end-to-end by
//! `lyric-testing`'s real `MockDbConnection`/`MockDbTransaction` mocks
//! (`lyric-testing/tests/testing_tests.l`) calling into `lyric-db`'s real
//! `DbConnection.transaction(): Result[DbTransaction, DbError]` — this file
//! does not duplicate that cross-package shape.
//!
//! This file instead mirrors the ORIGINAL five-mock-type bisection shape as
//! closely as a single self-contained `Std.*`-only package allows: five
//! distinct interface/record pairs declared in ONE file/package, one of
//! which (`DbLikeConn`/`DbLikeTxn`) returns an interface type wrapped in
//! `Result` (mirroring `DbConnection.transaction()`) with a further
//! interface method dispatched on the value extracted via `match`, and
//! another (`SearchLikeClient`) using `async func` interface methods
//! (mirroring `Search.SearchClient`, the point at which the original
//! bisection's second failure appeared once added alongside the Db pair).
//! Every pair's methods are exercised by tests so a "pre-existing code
//! broke once more impl blocks were added" regression would show up as a
//! failing assertion here, same as it did in the original report.
//!
//! Run in CI via native `lyric test --target dotnet`. Imports only `Std.*`.
@test_module
package Lyric.MultiImplIfaceResultSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ── Pair 1: Db-like (interface-returning-interface via Result) ────────────
interface DbLikeTxn {
  func query(sql: in String): Result[Int, String]
  func commit(): Result[Unit, String]
  func rollback(): Result[Unit, String]
}

interface DbLikeConn {
  func query(sql: in String): Result[Int, String]
  func execute(sql: in String): Result[Int, String]
  func transaction(): Result[DbLikeTxn, String]
  func close(): Unit
}

record MockDbLikeTxn {
  committed: Bool
}

impl DbLikeTxn for MockDbLikeTxn {
  func query(sql: in String): Result[Int, String] {
    Ok(sql.length)
  }
  func commit(): Result[Unit, String] {
    Ok(())
  }
  func rollback(): Result[Unit, String] {
    Ok(())
  }
}

record MockDbLikeConn {
  label: String
}

impl DbLikeConn for MockDbLikeConn {
  func query(sql: in String): Result[Int, String] {
    Ok(sql.length + self.label.length)
  }
  func execute(sql: in String): Result[Int, String] {
    Ok(1)
  }
  func transaction(): Result[DbLikeTxn, String] {
    val tx: DbLikeTxn = MockDbLikeTxn(committed = false)
    Ok(tx)
  }
  func close(): Unit {
    ()
  }
}

// ── Pair 2: Search-like (async interface methods) ─────────────────────────
interface SearchLikeClient {
  async func index(id: in String): Result[Unit, String]
  async func search(query: in String): Result[Int, String]
  async func exists(id: in String): Result[Bool, String]
  async func delete(id: in String): Result[Unit, String]
}

record MockSearchLikeClient {
  indexed: Int
}

impl SearchLikeClient for MockSearchLikeClient {
  async func index(id: in String): Result[Unit, String] {
    Ok(())
  }
  async func search(query: in String): Result[Int, String] {
    Ok(query.length)
  }
  async func exists(id: in String): Result[Bool, String] {
    Ok(id.length > 0)
  }
  async func delete(id: in String): Result[Unit, String] {
    Ok(())
  }
}

// ── Pair 3: Queue-consumer-like ────────────────────────────────────────────
interface QueueLikeConsumer {
  func subscribe(topic: in String): Result[Unit, String]
  func ack(id: in String): Result[Unit, String]
  func nack(id: in String): Result[Unit, String]
}

record MockQueueLikeConsumer {
  topicCount: Int
}

impl QueueLikeConsumer for MockQueueLikeConsumer {
  func subscribe(topic: in String): Result[Unit, String] {
    Ok(())
  }
  func ack(id: in String): Result[Unit, String] {
    Ok(())
  }
  func nack(id: in String): Result[Unit, String] {
    Ok(())
  }
}

// ── Pair 4: Ws-handler-like + Ws-registry-like (two interfaces, two records) ─
interface WsLikeHandler {
  func onConnect(clientId: in String): Unit
  func onMessage(clientId: in String, body: in String): Result[String, String]
  func onClose(clientId: in String): Unit
}

interface WsLikeRegistry {
  func register(clientId: in String): Result[Unit, String]
  func broadcast(body: in String): Result[Int, String]
}

record MockWsLikeHandler {
  connects: Int
}

impl WsLikeHandler for MockWsLikeHandler {
  func onConnect(clientId: in String): Unit {
    ()
  }
  func onMessage(clientId: in String, body: in String): Result[String, String] {
    Ok(body)
  }
  func onClose(clientId: in String): Unit {
    ()
  }
}

record MockWsLikeRegistry {
  registered: Int
}

impl WsLikeRegistry for MockWsLikeRegistry {
  func register(clientId: in String): Result[Unit, String] {
    Ok(())
  }
  func broadcast(body: in String): Result[Int, String] {
    Ok(body.length)
  }
}

// ── Pair 5: a second interface-returning-interface-via-Option pair ────────
interface SessionLikeStore {
  func touch(): Result[Unit, String]
}

interface SessionLikeFactory {
  func open(id: in String): Option[SessionLikeStore]
}

record MockSessionLikeStore {
  id: String
}

impl SessionLikeStore for MockSessionLikeStore {
  func touch(): Result[Unit, String] {
    Ok(())
  }
}

record MockSessionLikeFactory {
  seed: Int
}

impl SessionLikeFactory for MockSessionLikeFactory {
  func open(id: in String): Option[SessionLikeStore] {
    if id.length > 0 {
      val store: SessionLikeStore = MockSessionLikeStore(id = id)
      Some(store)
    } else {
      None
    }
  }
}

// ── Tests: exercise every pair, including calls on interface values
//    extracted via `match` from a Result/Option (the interface-through-
//    Result pattern) — mirrors #5133's bisection shape. ──────────────────
test "DbLikeConn: query/execute work directly on the connection" {
  val conn: DbLikeConn = MockDbLikeConn(label = "primary")
  match conn.query("select 1") {
    case Ok(n) -> assertEqualInt(n, 15, "query length includes label")
    case Err(_) -> assertTrue(false, "query() must return Ok")
  }
  match conn.execute("insert") {
    case Ok(n) -> assertEqualInt(n, 1, "execute returns affected rows")
    case Err(_) -> assertTrue(false, "execute() must return Ok")
  }
}

test "DbLikeConn: transaction() returns an interface value dispatched after a Result match" {
  val conn: DbLikeConn = MockDbLikeConn(label = "x")
  match conn.transaction() {
    case Ok(tx) -> {
      match tx.commit() {
        case Ok(_) -> assertTrue(true, "commit ok")
        case Err(_) -> assertTrue(false, "tx.commit() must return Ok")
      }
      match tx.query("select 2") {
        case Ok(n) -> assertEqualInt(n, 8, "tx.query length")
        case Err(_) -> assertTrue(false, "tx.query() must return Ok")
      }
      match tx.rollback() {
        case Ok(_) -> assertTrue(true, "rollback ok")
        case Err(_) -> assertTrue(false, "tx.rollback() must return Ok")
      }
    }
    case Err(_) -> assertTrue(false, "transaction() must return Ok")
  }
}

test "SearchLikeClient: index, exists (x2), delete through the same binding" {
  val client: SearchLikeClient = MockSearchLikeClient(indexed = 0)
  match await client.index("doc-1") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "index() must return Ok")
  }
  val e1 = await client.exists("doc-1")
  match e1 {
    case Ok(v) -> assertTrue(v, "doc-1 exists after index")
    case Err(_) -> assertTrue(false, "exists() must return Ok")
  }
  val e2 = await client.exists("")
  match e2 {
    case Ok(v) -> assertTrue(not v, "empty id does not exist")
    case Err(_) -> assertTrue(false, "exists() must return Ok")
  }
  match await client.delete("doc-1") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "delete() must return Ok")
  }
}

test "SearchLikeClient: search returns query length via async dispatch" {
  val client: SearchLikeClient = MockSearchLikeClient(indexed = 0)
  val r = await client.search("widget")
  match r {
    case Ok(n) -> assertEqualInt(n, 6, "search result length")
    case Err(_) -> assertTrue(false, "search() must return Ok")
  }
}

test "QueueLikeConsumer: subscribe/ack/nack" {
  val c: QueueLikeConsumer = MockQueueLikeConsumer(topicCount = 0)
  assertTrue(isOk(c.subscribe("orders")), "subscribe ok")
  assertTrue(isOk(c.ack("m-1")), "ack ok")
  assertTrue(isOk(c.nack("m-2")), "nack ok")
}

test "WsLikeHandler + WsLikeRegistry: independent interface/record pairs stay correct together" {
  val h: WsLikeHandler = MockWsLikeHandler(connects = 0)
  h.onConnect("c-1")
  match h.onMessage("c-1", "hello") {
    case Ok(echoed) -> assertEqual(echoed, "hello", "onMessage echoes body")
    case Err(_) -> assertTrue(false, "onMessage() must return Ok")
  }
  h.onClose("c-1")

  val reg: WsLikeRegistry = MockWsLikeRegistry(registered = 0)
  assertTrue(isOk(reg.register("c-1")), "register ok")
  match reg.broadcast("hi all") {
    case Ok(n) -> assertEqualInt(n, 6, "broadcast returns body length")
    case Err(_) -> assertTrue(false, "broadcast() must return Ok")
  }
}

test "SessionLikeFactory: open() returns an interface value via Option, dispatched after match" {
  val factory: SessionLikeFactory = MockSessionLikeFactory(seed = 1)
  match factory.open("sess-1") {
    case Some(store) -> {
      match store.touch() {
        case Ok(_) -> assertTrue(true, "touch ok")
        case Err(_) -> assertTrue(false, "store.touch() must return Ok")
      }
    }
    case None -> assertTrue(false, "open() with a non-empty id must return Some")
  }
  match factory.open("") {
    case Some(_) -> assertTrue(false, "open() with an empty id must return None")
    case None -> assertTrue(true, "empty id correctly yields None")
  }
}

// ── Re-exercise Pair 1 and Pair 2 AFTER every other impl block in the file
//    (five pairs deep) to catch the exact "pre-existing, untouched mock
//    method starts failing once file size/impl-count grows" symptom #5133
//    reported — these two tests duplicate calls already covered above but
//    matter here because of WHERE they sit relative to the impl-block
//    count, not what they assert. ────────────────────────────────────────
test "DbLikeConn re-check after four more impl pairs were added to the file" {
  val conn: DbLikeConn = MockDbLikeConn(label = "re-check")
  match conn.transaction() {
    case Ok(tx) -> {
      match tx.commit() {
        case Ok(_) -> assertTrue(true, "commit still resolves correctly at file-scale")
        case Err(_) -> assertTrue(false, "tx.commit() token must still resolve at file-scale")
      }
    }
    case Err(_) -> assertTrue(false, "transaction() must still return Ok at file-scale")
  }
}

test "SearchLikeClient re-check after four more impl pairs were added to the file" {
  val client: SearchLikeClient = MockSearchLikeClient(indexed = 0)
  val r = await client.search("recheck")
  match r {
    case Ok(n) -> assertEqualInt(n, 7, "search still resolves correctly at file-scale")
    case Err(_) -> assertTrue(false, "search() must still return Ok at file-scale")
  }
}
