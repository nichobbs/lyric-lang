//! msil_self_test_m85.l — Stage M85: IConfig (config block) lowering.
//!
//! Exercises the `config BlockName { field: Type = default }` lowering path
//! added in issue #1508 and extended to the full v1 type set
//! (Bool/Int/Long/Float/Double/String) in #2993.  The compiled binary reads
//! environment variables at .cctor time; when they are absent the default
//! values are used.
//!
//! Checks:
//!   * Int / Bool / String / Long / Float / Double fields with defaults use
//!     the default when the env var is absent (including a negated Float
//!     default and a Long default outside Int32 range).
//!   * A second config block in the same package is lowered independently.
//!   * The EnvProbe block's fields parse from env vars when set: CI runs this
//!     program twice — without the LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_*
//!     vars (expecting *_parsed=false) and with them (expecting *_parsed=true),
//!     which exercises Int32.Parse / Int64.Parse / Boolean.Parse and the
//!     culture-pinned Double.Parse(string, IFormatProvider) paths.
//!   * Config field access compiles and runs without panic.
//!
//! Manual run (defaults path):
//!   ./bin/lyric run lyric-compiler/msil/msil_self_test_m85.l
//!
//! Manual run (env-parse path):
//!   LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_EPORT=4242 \
//!   LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ERATE=2.5 \
//!   LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ECAP=8589934592 \
//!   LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_EFLAG=true \
//!   LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ENAME=from-env \
//!   ./bin/lyric run lyric-compiler/msil/msil_self_test_m85.l
//!
//! Expected stdout (defaults run: every *_default=true, every *_parsed=false;
//! env run: every *_default=true, every *_parsed=true).
//!
//! CI wiring: the "IConfig config-block lowering self-test" step in
//! .github/workflows/ci.yml runs both invocations via `lyric run`.
package Msil.SelfTestM85

config Settings {
  port: Int = 8080
  debug: Bool = false
  name: String = "default-app"
  rate: Float = 0.25
  scale: Double = -1.5
  cap: Long = 9000000000
}

config Database {
  timeout: Int = 30
}

config EnvProbe {
  eport: Int = 1
  erate: Float = 0.0
  ecap: Long = 0
  eflag: Bool = false
  ename: String = "unset"
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
  check("rate_default", Settings.rate == 0.25)
  check("scale_default", Settings.scale == -1.5)
  check("cap_default", Settings.cap == 9000000000)
  check("timeout_default", Database.timeout == 30)
  check("eport_parsed", EnvProbe.eport == 4242)
  check("erate_parsed", EnvProbe.erate == 2.5)
  check("ecap_parsed", EnvProbe.ecap == 8589934592)
  check("eflag_parsed", EnvProbe.eflag == true)
  check("ename_parsed", EnvProbe.ename == "from-env")
  check("access_no_panic", true)
}
