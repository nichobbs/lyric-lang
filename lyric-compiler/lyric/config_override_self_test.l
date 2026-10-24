//! config_override_self_test.l - the config-override seam (D230, #7181) on
//! BOTH targets.
//!
//! A `config { }` block is initialised once, on its first access.  Its
//! initialiser reads the override store (`Std.ConfigOverride`) before the
//! environment and the declared default: the .NET `.cctor` through
//! `AppDomain.GetData`, the JVM `<clinit>` through `System.getProperty`.
//! Each case below owns a config block that nothing touches before its
//! `setConfigOverride` call, because the initialiser runs only once.
//!
//! Run via `lyric test lyric-compiler/lyric/config_override_self_test.l` and
//! with `--target jvm` (scripts/ci/compiler-self-tests-batch.sh and
//! scripts/ci/jvm-generics-self-tests-batch.sh).
@test_module
package Lyric.ConfigOverrideSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment as Env
import Std.ConfigOverride
import Std.AnnotationMeta

config Plain {
  host: String = "default-host"
}

config AllTypes {
  port: Int = 1
  limit: Long = 1
  rate: Float = 1.0
  ratio: Double = 1.0
  enabled: Bool = false
  enabledAlt: Bool = false
  disabled: Bool = true
  name: String = "default"
}

config Required {
  secret: String
}

config Precedence {
  host: String = "default-host"
}

config Cleared {
  host: String = "default-host"
}

config Late {
  host: String = "default-host"
}

config Annotated {
  @sensitive
  @secretsManager("my-service/prod", key = "token")
  token: String
}

config Leak {
  host: String = "default-host"
}

func mustSet(key: in String, value: in String): Unit {
  match setConfigOverride(key, value) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setConfigOverride failed: " + Std.ConfigOverride.errorMessage(e))
  }
}

func mustClear(key: in String): Unit {
  match clearConfigOverride(key) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "clearConfigOverride failed: " + Std.ConfigOverride.errorMessage(e))
  }
}

test "an override replaces the declared default" {
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_PLAIN_HOST", "from-override")
  assertEqual(Plain.host, "from-override", "String field takes the override")
}

test "an override feeds every config field type" {
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_PORT", "9090")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_LIMIT", "4294967296")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_RATE", "2.5")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_RATIO", "3.5")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_ENABLED", "true")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_ENABLEDALT", "1")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_DISABLED", "FALSE")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ALLTYPES_NAME", "from-override")
  assertEqualInt(AllTypes.port, 9090, "Int")
  assertEqualLong(AllTypes.limit, 4294967296, "Long")
  assertTrue(AllTypes.rate == 2.5f32, "Float")
  assertTrue(AllTypes.ratio == 3.5, "Double")
  assertTrue(AllTypes.enabled, "Bool true")
  assertTrue(AllTypes.enabledAlt, "Bool 1")
  assertFalse(AllTypes.disabled, "Bool FALSE")
  assertEqual(AllTypes.name, "from-override", "String")
}

test "an override satisfies a required field that would otherwise abort with exit 78" {
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_REQUIRED_SECRET", "s3cr3t")
  assertEqual(Required.secret, "s3cr3t", "required field read from the override")
}

test "an override wins over an environment variable" {
  Env.setVar("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_PRECEDENCE_HOST", "from-env")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_PRECEDENCE_HOST", "from-override")
  assertEqual(Precedence.host, "from-override", "override beats env")
}

test "clearing an override restores the default" {
  val key = "LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_CLEARED_HOST"
  mustSet(key, "from-override")
  assertSomeValue(getConfigOverride(key), "from-override", "registered")
  mustClear(key)
  assertTrue(getConfigOverride(key) == None, "cleared")
  assertEqual(Cleared.host, "default-host", "a cleared override leaves the default")
}

test "a value registered after the first read is not seen" {
  assertEqual(Late.host, "default-host", "first read initialises the block")
  mustSet("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_LATE_HOST", "too-late")
  assertEqual(Late.host, "default-host", "the block is initialised once")
}

test "the key the compiler records for a field is the key the initialiser reads" {
  match fieldsWithAnnotation("secretsManager") {
    case Err(e) -> assertTrue(false, "annotation metadata unavailable: " + Std.AnnotationMeta.errorMessage(e))
    case Ok(fs) -> {
      var found = false
      var i = 0
      while i < fs.count {
        if fs[i].configName == "Annotated" {
          found = true
          assertEqual(fs[i].envVar, "LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_ANNOTATED_TOKEN", "recorded env var name")
          mustSet(fs[i].envVar, "vaulted")
        }
        i = i + 1
      }
      assertTrue(found, "the Annotated.token field is in the metadata")
    }
  }
  assertEqual(Annotated.token, "vaulted", "a value registered under the recorded key reaches the field")
}

test "a registered value is not placed in the process environment" {
  val key = "LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_LEAK_HOST"
  mustSet(key, "secret-value")
  match Env.getVar(key) {
    case Ok(v) -> assertTrue(false, "the override leaked into the environment: " + v)
    case Err(_) -> ()
  }
  assertEqual(Leak.host, "secret-value", "but the config block reads it")
}

test "only LYRIC_CONFIG_ keys are accepted" {
  match setConfigOverride("PATH", "x") {
    case Err(InvalidKey(k)) -> assertEqual(k, "PATH", "rejected key")
    case _ -> assertTrue(false, "PATH must be an InvalidKey")
  }
  match setConfigOverride("LYRIC_CONFIG_", "x") {
    case Err(InvalidKey(_)) -> ()
    case _ -> assertTrue(false, "the bare prefix must be an InvalidKey")
  }
  match clearConfigOverride("java.class.path") {
    case Err(InvalidKey(_)) -> ()
    case _ -> assertTrue(false, "clear applies the same key check")
  }
}

test "a value containing NUL is rejected" {
  match setConfigOverride("LYRIC_CONFIG_LYRIC_CONFIGOVERRIDESELFTEST_NUL_X", "a\u{0000}b") {
    case Err(InvalidValue(_)) -> ()
    case _ -> assertTrue(false, "a NUL value must be an InvalidValue")
  }
}

test "the seam is supported on this target" {
  assertTrue(isSupported(), "dotnet and jvm consult the override store")
}

func assertSomeValue(o: in Option[String], expected: in String, label: in String): Unit {
  match o {
    case Some(v) -> assertEqual(v, expected, label)
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}
