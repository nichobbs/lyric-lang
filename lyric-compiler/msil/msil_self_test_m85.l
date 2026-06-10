//! msil_self_test_m85.l — Stage M85: IConfig (config block) lowering.
//!
//! Exercises the `config BlockName { field: Type = default }` lowering path
//! added in issue #1508.  The compiled binary reads environment variables at
//! .cctor time; when they are absent the default values are used, which is
//! what this test exercises (no env-var injection required).
//!
//! Checks:
//!   * Int field with default uses the default when the env var is absent.
//!   * Bool field with default uses the default when the env var is absent.
//!   * String field with default uses the default when the env var is absent.
//!   * A second config block in the same package is lowered independently.
//!   * Config field access compiles and runs without panic.
//!
//! Manual run:
//!   ./bin/lyric run lyric-compiler/msil/msil_self_test_m85.l
//!
//! Expected stdout (all checks print "=true"):
//!   port_default=true
//!   debug_default=true
//!   name_default=true
//!   timeout_default=true
//!   access_no_panic=true
//!
//! CI wiring: not yet wired — requires F# emitter test runner which cannot
//! be added per CLAUDE.md.  Tracked in #2983.
package Msil.SelfTestM85

config Settings {
  port: Int = 8080
  debug: Bool = false
  name: String = "default-app"
}

config Database {
  timeout: Int = 30
}

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=false")
  }
}

func main(): Unit {
  check("port_default", Settings.port == 8080)
  check("debug_default", Settings.debug == false)
  check("name_default", Settings.name == "default-app")
  check("timeout_default", Database.timeout == 30)
  check("access_no_panic", true)
}
