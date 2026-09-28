//! config_block_no_env_import_self_test.l: a `config { }` block in a file
//! whose stdlib import closure never reaches `Std.Environment` (#7594).
//!
//! On `--target jvm` every config block's `<clinit>` reads
//! `Std.EnvironmentHost.envOverlay` so a runtime `Std.Environment.setVar`
//! is observed. That `getstatic` needs `Std.EnvironmentHost` in the bundled
//! JAR, and before #7594 the bundler only included it when the program
//! imported `Std.Environment` itself; this file then failed at class load
//! with `NoClassDefFoundError`. `Jvm.Bridge` now adds it whenever any
//! compilation unit declares a config block.
//!
//! Keep the imports to `Std.Core` and `Std.Testing`: neither reaches
//! `Std.Environment` or `Std.EnvironmentHost`, which is what makes this a
//! regression pin (`config_block_self_test.l` imports `Std.Environment` for
//! its `setVar` case and so cannot cover this). Runs on both targets.
@test_module
package Lyric.ConfigBlockNoEnvImportSelfTest

import Std.Core
import Std.Testing

config Settings {
  port: Int = 7070
  host: String = "localhost"
  verbose: Bool = false
}

test "config defaults load without Std.Environment in the import closure" {
  assertEqualInt(Settings.port, 7070, "Int default")
  assertEqual(Settings.host, "localhost", "String default")
  assertFalse(Settings.verbose, "Bool default")
}
