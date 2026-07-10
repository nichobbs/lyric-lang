//! tests/session_config_env_tests.l — unit coverage for `parseSessionTtlSeconds`
//! (review finding #4842: the `t > 0` guard — reject zero/negative/non-numeric,
//! accept positive — had no test coverage). A regression that weakened the
//! guard (e.g. `t >= 0` or `t != 0`) would silently allow a zero-second TTL,
//! causing Redis SETEX/EXPIRE to immediately expire every session.
@test_module
package Session.SessionConfigEnvTests

import Std.Core
import Std.Testing
import Session as Session

test "parseSessionTtlSeconds: a positive value is accepted" {
  assertEqualInt(Session.parseSessionTtlSeconds("3600", 1800), 3600, "positive TTL parses through")
}

test "parseSessionTtlSeconds: a small positive value (1) is accepted" {
  assertEqualInt(Session.parseSessionTtlSeconds("1", 1800), 1, "TTL of 1 second is accepted")
}

test "parseSessionTtlSeconds: zero is rejected and falls back to the default" {
  assertEqualInt(
    Session.parseSessionTtlSeconds("0", 1800),
    1800,
    "TTL of 0 must not pass through — Redis SETEX/EXPIRE require a strictly positive TTL"
  )
}

test "parseSessionTtlSeconds: a negative value is rejected and falls back to the default" {
  assertEqualInt(Session.parseSessionTtlSeconds("-1", 1800), 1800, "negative TTL falls back to default")
}

test "parseSessionTtlSeconds: a non-numeric value is rejected and falls back to the default" {
  assertEqualInt(Session.parseSessionTtlSeconds("not-a-number", 1800), 1800, "non-numeric TTL falls back to default")
}

test "parseSessionTtlSeconds: an empty string is rejected and falls back to the default" {
  assertEqualInt(Session.parseSessionTtlSeconds("", 1800), 1800, "empty TTL string falls back to default")
}
