// Lambda.Aspects — pub aspect templates for cross-cutting Lambda handler concerns.
//
// Provides two reusable template aspects:
//
//   EventLogging  — logs the handler's qualified name, outcome (ok/err), and
//                   elapsed time for every matched invocation.
//                   B-mode: uses call.qualifiedName only; composes generically
//                   across all matched handlers regardless of parameter shape.
//
//   DeadlineGuard — checks ctx.remainingTimeMs before dispatching the call
//                   and short-circuits with LambdaError.TimeoutError if the
//                   Lambda deadline is too close.
//                   C-mode (@inline_template): reads args.ctx — the matched
//                   handler must declare a parameter named
//                   `ctx: Lambda.LambdaContext`.
//
// Typical consumer instantiation:
//
//   import Lambda.Aspects
//
//   aspect LogAll from Lambda.Aspects.EventLogging {
//     matches: name like "handle*"
//   }
//
//   aspect GuardDeadline from Lambda.Aspects.DeadlineGuard {
//     matches: name like "handle*"
//     inside:  LogAll
//     config {
//       thresholdMs: Long = 1000
//     }
//   }
//
// See docs/26-aspects.md §18, docs/27-aspect-libraries.md, docs/35-lambda-library.md.

@runtime_checked
package Lambda.Aspects

import Std.Core
import Lambda

// ─── EventLogging ─────────────────────────────────────────────────────────────

/// Log the handler name, outcome, and elapsed time for every matched call.
///
/// B-mode: body uses only call.qualifiedName so it composes generically
/// across all matched handlers regardless of their parameter shapes.
/// Compose this as the outer aspect (inside: EventLogging) around DeadlineGuard
/// so deadline rejections are also logged.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled  Bool   — master switch (default: true)
///   logLevel String — log severity: DEBUG, INFO, WARN, ERROR (default: "INFO")
@stable(since="0.1")
pub aspect EventLogging {
  config {
    enabled:  Bool   = true
    logLevel: String = "INFO"
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val startMs = Std.Core.currentTimeMs()
      ret = call.proceed()
      val elapsedMs = Std.Core.currentTimeMs() - startMs
      val outcome = match ret {
        Ok(_)  => "ok"
        Err(_) => "err"
      }
      Std.Core.log(logLevel,
        call.qualifiedName + " " + outcome + " " + elapsedMs.toString() + "ms")
    }
  }
}

// ─── DeadlineGuard ───────────────────────────────────────────────────────────

/// Short-circuit a handler call when the Lambda deadline is too close.
///
/// Checks ctx.remainingTimeMs before proceeding.  If the remaining time is at
/// or below thresholdMs the aspect returns LambdaError.TimeoutError without
/// invoking the handler, giving the caller time to log and return cleanly
/// before the Lambda runtime forcibly terminates the process.
///
/// C-mode (@inline_template): reads args.ctx — every matched handler must
/// declare a parameter named `ctx: Lambda.LambdaContext`.  The compiler
/// reports shape error A0042 if the parameter is absent.
///
/// Use inside: EventLogging so deadline rejections appear in the logs.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled     Bool — master switch (default: true)
///   thresholdMs Long — bail-out threshold in milliseconds (default: 500)
@stable(since="0.1")
@inline_template
pub aspect DeadlineGuard {
  config {
    enabled:     Bool = true
    thresholdMs: Long = 500
  }

  requires:
    args.ctx != null   // handler must declare ctx: Lambda.LambdaContext

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.ctx.remainingTimeMs <= thresholdMs {
        ret = Err(Lambda.LambdaError.TimeoutError(remainingMs = args.ctx.remainingTimeMs))
      } else {
        ret = call.proceed()
      }
    }
  }
}
