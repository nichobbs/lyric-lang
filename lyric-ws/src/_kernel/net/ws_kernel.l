// Ws.Kernel.Net — ASP.NET Core WebSockets extern boundary.
//
// Bridges the Ws package to the ASP.NET Core WebSocket infrastructure.
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Ws.Kernel.Net

import Std.Core

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func createRegistry(maxMessageSizeBytes: Int, pingIntervalMs: Int): Result[Int, String] = Ok(0)

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func send(registryHandle: Int, connectionId: String, messageType: String, data: String): Result[Unit, String] = Ok(())

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func broadcast(registryHandle: Int, messageType: String, data: String): Result[Unit, String] = Ok(())

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func close(registryHandle: Int, connectionId: String, code: Int, reason: String): Result[Unit, String] = Ok(())

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func connectionCount(registryHandle: Int): Int = 0

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
pub func isConnected(registryHandle: Int, connectionId: String): Bool = false

@axiom("In-process sliding-window rate limiter (System.Threading.RateLimiting)")
pub func checkRateLimit(key: String, messagesPerMinute: Int, burstSize: Int): Bool = false
