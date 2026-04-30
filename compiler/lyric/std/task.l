// std/task.l - async task and cancellation shapes.
//
// This is a source-level facade for future async runtime integration.
// It intentionally avoids exposing raw host Task or CancellationToken
// objects to application code.

@runtime_checked
package Std.Task

generic[T] pub opaque type Task {
  marker: Unit
}

pub opaque type CancellationToken {
  marker: Unit
}

pub opaque type CancellationSource {
  marker: Unit
}

/// A token that is never cancelled.
pub func CancellationToken.none(): CancellationToken {
  return CancellationToken(marker = ())
}

/// Create a source that can cancel work which observes its token.
pub func CancellationSource.make(): CancellationSource {
  return CancellationSource(marker = ())
}

/// Return the token controlled by this source.
pub func CancellationSource.token(source: in CancellationSource): CancellationToken {
  return CancellationToken(marker = ())
}

/// Request cancellation.
///
/// Cancellation is cooperative: async operations must explicitly accept
/// and observe a CancellationToken.
pub func CancellationSource.cancel(source: in CancellationSource): Unit {
  ()
}
