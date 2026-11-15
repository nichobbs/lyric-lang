//! Testing.Conformance.Session — conformance suite for `Session.SessionStore`.
//!
//! `run(factory)`: `factory` returns a fresh, empty store every call.
//!
//! The suite pins the secure behaviour, which differs from what an older
//! doc comment on `SessionStore.set` promised: `set`, like every other write
//! on an id the store does not hold, never creates a session (that would let
//! an attacker pick the id of a session a victim later uses, session
//! fixation, #316).  A caller obtains an id from `create`.  Expiry is not
//! covered, since the interface exposes no clock to drive it.
@runtime_checked
@io
package Testing.Conformance.Session

import Std.Core
import Std.Collections
import Testing.Conformance
import Session as SessionLib

/// Run the `SessionStore` contract against stores from `factory`.
@stable(since = "0.1")
pub func run(factory: () -> SessionLib.SessionStore): Checks {
  val c = newChecks("SessionStore")
  runCase(c, "create issues valid, distinct ids", { -> createIds(c, factory()) })
  runCase(c, "a created session loads empty", { -> loadCreated(c, factory()) })
  runCase(c, "an unknown or malformed id loads as None", { -> loadUnknown(c, factory()) })
  runCase(c, "set then get returns the value", { -> setGet(c, factory()) })
  runCase(c, "set overwrites and keys are independent", { -> overwriteAndIndependence(c, factory()) })
  runCase(c, "get of an absent key or an unknown session is None", { -> getAbsent(c, factory()) })
  runCase(c, "set on an unknown session fails and does not create it", { -> setDoesNotCreate(c, factory()) })
  runCase(c, "delete removes one key and tolerates an absent one", { -> deleteKey(c, factory()) })
  runCase(c, "clear removes every key but keeps the session", { -> clearKeys(c, factory()) })
  runCase(c, "destroy removes the session and tolerates an unknown one", { -> destroySession(c, factory()) })
  runCase(c, "save replaces the stored data", { -> saveReplaces(c, factory()) })
  runCase(c, "save rejects a malformed id", { -> saveRejectsBadId(c, factory()) })
  runCase(c, "touch keeps the contents and tolerates an unknown session", { -> touchKeeps(c, factory()) })
  runCase(c, "sessions are isolated from each other", { -> isolation(c, factory()) })
  runCase(c, "the convenience wrappers agree with the interface", { -> wrappers(c, factory()) })
  return c
}

// The id of a newly created session; records a failure and returns "" when
// `create` itself fails, so the calling case can end.
func newSession(c: in Checks, store: in SessionLib.SessionStore): String {
  match store.create() {
    case Ok(id) -> return id
    case Err(e) -> {
      failCase(c, "create failed: " + e.message)
      return ""
    }
  }
}

func valueOf(c: in Checks, store: in SessionLib.SessionStore, id: in String, key: in String): Option[String] {
  match store.get(id, key) {
    case Ok(v) -> return v
    case Err(e) -> {
      failCase(c, "get(" + key + ") failed: " + e.message)
      return None
    }
  }
}

func okOrFail(c: in Checks, result: in Result[Unit, SessionLib.SessionError], what: in String): Unit {
  match result {
    case Ok(_) -> expectTrue(c, true, what)
    case Err(e) -> failCase(c, what + " failed: " + e.message)
  }
}

func createIds(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val a = newSession(c, store)
  val b = newSession(c, store)
  expectTrue(c, SessionLib.isValidSessionId(a), "the first id is a valid session id")
  expectTrue(c, SessionLib.isValidSessionId(b), "the second id is a valid session id")
  expectTrue(c, a != b, "two creates issue different ids")
}

func loadCreated(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  match store.load(id) {
    case Ok(Some(d)) -> {
      expectEqual(c, d.id, id, "the loaded data carries the session id")
      expectEqualInt(c, d.entries.count, 0, "a new session has no entries")
      expectTrue(c, d.createdAt > 0i64, "createdAt is set")
    }
    case Ok(None) -> failCase(c, "a created session must load")
    case Err(e) -> failCase(c, "load failed: " + e.message)
  }
}

func loadUnknown(c: in Checks, store: in SessionLib.SessionStore): Unit {
  for id in ["no-such-session", "", "../escape", "has space", "semi;colon"] {
    match store.load(id) {
      case Ok(None) -> expectTrue(c, true, "load of an unknown id")
      case Ok(Some(_)) -> failCase(c, "load(\"" + id + "\") found a session")
      case Err(e) -> failCase(c, "load(\"" + id + "\") should be Ok(None), got Err: " + e.message)
    }
  }
}

func setGet(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "user", "alice"), "set")
  expectSome(c, valueOf(c, store, id, "user"), "alice", "get after set")
  match store.load(id) {
    case Ok(Some(d)) -> expectSome(c, mapGet(d.entries, "user"), "alice", "load shows the entry")
    case _ -> failCase(c, "the session must load after set")
  }
}

func overwriteAndIndependence(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "a", "1"), "set a")
  okOrFail(c, store.set(id, "b", "2"), "set b")
  okOrFail(c, store.set(id, "a", "3"), "overwrite a")
  expectSome(c, valueOf(c, store, id, "a"), "3", "the second set wins")
  expectSome(c, valueOf(c, store, id, "b"), "2", "the other key is untouched")
}

func getAbsent(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  expectNone(c, valueOf(c, store, id, "absent"), "get of a key never set")
  expectNone(c, valueOf(c, store, "no-such-session", "k"), "get on an unknown session")
}

func setDoesNotCreate(c: in Checks, store: in SessionLib.SessionStore): Unit {
  match store.set("attacker-chosen-id", "k", "v") {
    case Err(e) -> expectEqual(c, e.code, "SESSION_NOT_FOUND", "the error code for an unknown session")
    case Ok(_) -> failCase(c, "set on an unknown session must fail (session fixation)")
  }
  match store.load("attacker-chosen-id") {
    case Ok(None) -> expectTrue(c, true, "the failed set did not create a session")
    case _ -> failCase(c, "set on an unknown session must not create it")
  }
}

func deleteKey(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "a", "1"), "set a")
  okOrFail(c, store.set(id, "b", "2"), "set b")
  okOrFail(c, store.delete(id, "a"), "delete a")
  expectNone(c, valueOf(c, store, id, "a"), "the deleted key is gone")
  expectSome(c, valueOf(c, store, id, "b"), "2", "the other key remains")
  okOrFail(c, store.delete(id, "a"), "deleting an absent key")
  okOrFail(c, store.delete("no-such-session", "a"), "deleting a key of an unknown session")
}

func clearKeys(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "a", "1"), "set a")
  okOrFail(c, store.set(id, "b", "2"), "set b")
  okOrFail(c, store.clear(id), "clear")
  expectNone(c, valueOf(c, store, id, "a"), "a cleared key")
  match store.load(id) {
    case Ok(Some(d)) -> expectEqualInt(c, d.entries.count, 0, "no entries remain")
    case _ -> failCase(c, "clear must keep the session")
  }
  okOrFail(c, store.clear("no-such-session"), "clearing an unknown session")
  okOrFail(c, store.set(id, "c", "3"), "set after clear")
  expectSome(c, valueOf(c, store, id, "c"), "3", "the session is usable after clear")
}

func destroySession(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "a", "1"), "set a")
  okOrFail(c, store.destroy(id), "destroy")
  match store.load(id) {
    case Ok(None) -> expectTrue(c, true, "the destroyed session no longer loads")
    case _ -> failCase(c, "a destroyed session must not load")
  }
  expectNone(c, valueOf(c, store, id, "a"), "a key of a destroyed session")
  okOrFail(c, store.destroy(id), "destroying it again")
  okOrFail(c, store.destroy("no-such-session"), "destroying an unknown session")
}

func saveReplaces(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "old", "x"), "set old")
  val entries: Map[String, String] = newMap()
  entries["fresh"] = "y"
  val data = SessionLib.SessionData(
    id = id,
    entries = entries,
    createdAt = 1000i64,
    lastAccessedAt = 2000i64,
    expiresAt = 0i64
  )
  okOrFail(c, store.save(data), "save")
  expectSome(c, valueOf(c, store, id, "fresh"), "y", "the saved entry")
  expectNone(c, valueOf(c, store, id, "old"), "an entry the saved data omitted")
}

func saveRejectsBadId(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val entries: Map[String, String] = newMap()
  val data = SessionLib.SessionData(
    id = "bad id/..",
    entries = entries,
    createdAt = 1i64,
    lastAccessedAt = 1i64,
    expiresAt = 0i64
  )
  match store.save(data) {
    case Err(_) -> expectTrue(c, true, "save of a malformed id is an Err")
    case Ok(_) -> failCase(c, "save must reject a malformed id")
  }
}

func touchKeeps(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val id = newSession(c, store)
  okOrFail(c, store.set(id, "a", "1"), "set a")
  okOrFail(c, store.touch(id), "touch")
  expectSome(c, valueOf(c, store, id, "a"), "1", "the entry survives a touch")
  okOrFail(c, store.touch("no-such-session"), "touching an unknown session")
}

func isolation(c: in Checks, store: in SessionLib.SessionStore): Unit {
  val a = newSession(c, store)
  val b = newSession(c, store)
  okOrFail(c, store.set(a, "k", "from-a"), "set in a")
  okOrFail(c, store.set(b, "k", "from-b"), "set in b")
  okOrFail(c, store.destroy(a), "destroy a")
  expectSome(c, valueOf(c, store, b, "k"), "from-b", "b survives the destruction of a")
}

func wrappers(c: in Checks, store: in SessionLib.SessionStore): Unit {
  match SessionLib.create(store) {
    case Err(e) -> failCase(c, "Session.create failed: " + e.message)
    case Ok(id) -> {
      okOrFail(c, SessionLib.set(store, id, "k", "v"), "Session.set")
      match SessionLib.get(store, id, "k") {
        case Ok(v) -> expectSome(c, v, "v", "Session.get")
        case Err(e) -> failCase(c, "Session.get failed: " + e.message)
      }
      okOrFail(c, SessionLib.destroy(store, id), "Session.destroy")
    }
  }
}
