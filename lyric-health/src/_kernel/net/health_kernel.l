//! Health.Kernel.Net — bounded-wait extern boundary for check timeouts.
//!
//! `--target dotnet` only: called exclusively from `Health`'s
//! `@cfg(feature = "dotnet")` check runner, so this package is dropped
//! from a `--target jvm` build by ordinary reachability pruning (the
//! same pattern `Auth.Kernel.Net` already relies on — its BCL-only
//! externs are never erased by an explicit `@cfg` on this package, only
//! by nothing left calling them).
//!
//! Runs a health check's handler on a BCL thread-pool thread
//! (`Task.Run(Action)`) and blocks the calling thread for at most
//! `timeoutMs` (`Task.Wait(int)`, which returns `false` on timeout
//! instead of throwing). This is the same `Task.Run(Action)` bridging
//! `Std.Task.scopeSpawn` already relies on for genuine background
//! execution of an arbitrary `() -> Unit` closure on this target
//! (lyric-stdlib/std/_kernel/task.l, issue #5329: a closure passed
//! directly to a BCL `Action`-typed parameter is really invoked on a
//! thread-pool thread here — confirmed working, not merely declared).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Health.Kernel.Net

extern type Task = "System.Threading.Tasks.Task"

@axiom("System.Threading.Tasks.Task.Run(Action) — schedule a closure on the thread pool")
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
pub func runAction(action: in () -> Unit): Task = ()

@axiom("System.Threading.Tasks.Task.Wait(int) — block the caller up to timeoutMs; returns false on timeout")
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
pub func waitTask(t: in Task, timeoutMs: in Int): Bool = ()
