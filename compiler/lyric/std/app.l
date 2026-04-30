// std/app.l - minimal application host helpers.
//
// App helpers compose existing stdlib pieces. They should not hide IO,
// logging, or process exit policy from callers.

@runtime_checked
package Std.App

import Std.Errors { IOError }
import Std.File as File

pub opaque type Config {
  path: String
  rawText: String
}

/// Run a synchronous application main and convert Bug into an exit code.
///
/// # Behavior
/// - returns 0 when `main` completes.
/// - returns 1 when `main` raises Bug.
///
/// Applications that need richer top-level error reporting should catch
/// domain errors before they reach this host wrapper.
pub func run(main: func Unit): Int {
  return try {
    main()
    0
  } catch Bug as b {
    1
  }
}

/// Load a config file as raw text.
///
/// # Preconditions as data
/// - `configPath` must be non-empty; empty paths return
///   `Err(InvalidPath)` from `Std.File.readText`.
///
/// # Errors
/// Same error model as `File.readText`.
///
/// JSON/env binding is deliberately not hidden here. Future config
/// helpers can layer source-generated decoding on top of this raw
/// boundary.
pub func withConfig(configPath: in String): Result[Config, IOError] {
  match File.readText(configPath) {
    case Err(e) -> Err(error = e)
    case Ok(text) -> Ok(value = Config(path = configPath, rawText = text))
  }
}

/// Return the path a Config was loaded from.
@pure
pub func Config.path(config: in Config): String {
  return config.path
}

/// Return the raw config text.
@pure
pub func Config.rawText(config: in Config): String {
  return config.rawText
}
