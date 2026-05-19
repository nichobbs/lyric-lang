// Session.Kernel.Net — Redis extern boundary for distributed session storage.
//
// Bridges the Session package to StackExchange.Redis.
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "redis")
package Session.Kernel.Net

import Std.Core

@axiom("StackExchange.Redis: IConnectionMultiplexer.Connect + key-prefix registration")
@stable(since="0.1")
pub func connect(url: String, keyPrefix: String): Result[Int, String] = Ok(0)

@axiom("StackExchange.Redis: IDatabase.StringSet with UUID key and TTL")
@stable(since="0.1")
pub func create(storeHandle: Int, ttlSeconds: Int): Result[String, String] = Ok("")

@axiom("StackExchange.Redis: IDatabase.StringGet; empty string when key absent or expired")
@stable(since="0.1")
pub func load(storeHandle: Int, sessionId: String): Result[String, String] = Ok("")

@axiom("StackExchange.Redis: IDatabase.StringSet with existing TTL preserved")
@stable(since="0.1")
pub func save(storeHandle: Int, sessionJson: String): Result[Unit, String] = Ok(())

@axiom("StackExchange.Redis: IDatabase.KeyDelete; no-op when key absent")
@stable(since="0.1")
pub func destroy(storeHandle: Int, sessionId: String): Result[Unit, String] = Ok(())

@axiom("StackExchange.Redis: IDatabase.KeyExpire; ttlSeconds=0 leaves TTL unchanged")
@stable(since="0.1")
pub func touch(storeHandle: Int, sessionId: String, ttlSeconds: Int): Result[Unit, String] = Ok(())
